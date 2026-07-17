# Benchmark Chain.State.uncompact — the path behind prod
#   "state(uncompact:0x...) took Nms"
# in Model.ChainSql.state/1 when a jump block's compact state is loaded from DB.
#
# Jump blocks store a compact %Chain.State{}; do_state then runs State.uncompact/1
# (CAccountMap.uncompact_state/1). Warns when wall time > 2s.
#
# Run from repo root (no full app start):
#   mix run --no-start scripts/state_uncompact_bench.exs
#   mix run --no-start scripts/state_uncompact_bench.exs -- --accounts 14000 --slots 32
#   mix run --no-start scripts/state_uncompact_bench.exs -- --scenario all --warmup 1 --iters 3
#   mix run --no-start scripts/state_uncompact_bench.exs -- --eprof
#
# Scenarios:
#   sparse_jump     — many accounts, 1 slot each (typical DB jump-block shape)
#   fat_slots       — many accounts × slots/account (heavier compact payload)
#   nif_only        — CAccountMap.uncompact_state only (no %State{} wrap)
#   all             — run every scenario

defmodule StateUncompactBench do
  @moduledoc false

  alias Chain.State

  def main(argv \\ System.argv()) do
    argv = normalize_argv(argv)

    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          accounts: :integer,
          slots: :integer,
          warmup: :integer,
          iters: :integer,
          scenario: :string,
          eprof: :boolean,
          csv: :boolean
        ]
      )

    accounts = Keyword.get(opts, :accounts, 14_000)
    slots = Keyword.get(opts, :slots, 8)
    warmup = Keyword.get(opts, :warmup, 1)
    iters = Keyword.get(opts, :iters, 3)
    scenario = Keyword.get(opts, :scenario, "all")
    eprof? = Keyword.get(opts, :eprof, false)
    csv? = Keyword.get(opts, :csv, false)

    _ = CAccountMap.new()

    IO.puts(:stderr, """
    === State.uncompact bench (ChainSql state(uncompact:…)) ===
    accounts=#{accounts} slots/account=#{slots}
    warmup=#{warmup} iters=#{iters} scenario=#{scenario} eprof=#{eprof?}
    """)

    scenarios =
      case scenario do
        "all" ->
          [
            {:sparse_jump, fn -> build_compact_state(accounts, 1) end},
            {:fat_slots, fn -> build_compact_state(accounts, slots) end},
            {:nif_only, fn -> build_compact_state(accounts, slots) end}
          ]

        name ->
          builder =
            case name do
              "sparse_jump" -> fn -> build_compact_state(accounts, 1) end
              "fat_slots" -> fn -> build_compact_state(accounts, slots) end
              "nif_only" -> fn -> build_compact_state(accounts, slots) end
              other -> raise "unknown --scenario #{inspect(other)}"
            end

          [{String.to_atom(name), builder}]
      end

    if csv? do
      IO.puts("scenario,iter,map_size,uncompact_ms,nif_ms,rss_kb")
    end

    Enum.each(scenarios, fn {name, builder} ->
      IO.puts(:stderr, "--- building #{name} ---")
      {build_us, compact} = :timer.tc(builder)
      map_size = compact_account_count(compact)

      IO.puts(
        :stderr,
        "built #{name} in #{div(build_us, 1000)}ms map_size=#{map_size} rss=#{div(read_rss_kb(), 1024)}MB"
      )

      for _ <- 1..warmup do
        _ = timed_uncompact(name, compact)
      end

      if eprof? do
        profile_eprof(name, compact)
      end

      samples =
        for i <- 1..iters do
          sample = timed_uncompact(name, compact)
          print_sample(name, i, map_size, sample, csv?)
          sample
        end

      summarize(name, samples)
    end)

    IO.puts(:stderr, """

    Interpretation hints:
    - Matches Model.ChainSql.do_state when DB row is %Chain.State{} (jump block).
    - Prod warning fires at >2000ms; sparse_jump ~14k accounts is the usual shape.
    - nif_ms ≈ uncompact_ms: cost is inside account_map_uncompact_state.
    """)
  end

  # What ChainSql times: State.uncompact/1 on a compact Elixir account map.
  defp timed_uncompact(:nif_only, %State{accounts: accounts}) when is_map(accounts) do
    {us, _} = :timer.tc(fn -> CAccountMap.uncompact_state(accounts) end)

    %{
      uncompact_ms: div(us, 1000),
      nif_ms: div(us, 1000),
      rss_kb: read_rss_kb()
    }
  end

  defp timed_uncompact(_name, %State{} = compact) do
    {api_us, _} = :timer.tc(fn -> State.uncompact(compact) end)

    %{
      uncompact_ms: div(api_us, 1000),
      nif_ms: div(api_us, 1000),
      rss_kb: read_rss_kb()
    }
  end

  defp print_sample(name, i, map_size, sample, true) do
    IO.puts("#{name},#{i},#{map_size},#{sample.uncompact_ms},#{sample.nif_ms},#{sample.rss_kb}")
  end

  defp print_sample(name, i, map_size, sample, false) do
    IO.puts(:stderr, """
    #{name} iter=#{i} map_size=#{map_size}
      uncompact_ms=#{sample.uncompact_ms} nif_ms=#{sample.nif_ms}
      rss_mb=#{div(sample.rss_kb, 1024)}
    """)
  end

  defp summarize(name, samples) do
    n = length(samples)
    avg = fn key -> div(Enum.sum(Enum.map(samples, &Map.fetch!(&1, key))), n) end

    IO.puts(
      :stderr,
      "SUMMARY #{name} avg_uncompact_ms=#{avg.(:uncompact_ms)} avg_nif_ms=#{avg.(:nif_ms)}"
    )
  end

  defp profile_eprof(name, %State{} = compact) do
    IO.puts(:stderr, "eprof #{name} (State.uncompact)...")
    :eprof.start()
    :eprof.profile(fn -> State.uncompact(compact) end)
    :eprof.analyze(:total)
    :eprof.stop()
  end

  defp build_compact_state(n, slots_per) do
    build_live_state(n, slots_per)
    |> State.normalize()
    |> State.lock()
    |> State.compact()
  end

  defp compact_account_count(%State{accounts: accounts}) when is_map(accounts),
    do: map_size(accounts)

  defp compact_account_count(%State{accounts: accounts}), do: CAccountMap.size(accounts)

  defp build_live_state(n, slots_per) do
    Enum.reduce(1..n, State.new(), fn i, st ->
      updates =
        for s <- 1..slots_per, into: %{} do
          {slot(i * 10_000 + s), <<i * 1000 + s::unsigned-size(256)>>}
        end

      State.set_account(st, addr(i), %Chain.Account{
        nonce: i,
        balance: i * 100,
        storage_root: Map.to_list(updates),
        code: <<i>>,
        map_backed: false
      })
    end)
  end

  defp addr(i), do: <<i::unsigned-size(160)>>
  defp slot(i), do: <<i::unsigned-size(256)>>

  defp read_rss_kb do
    case File.read("/proc/self/status") do
      {:ok, status} ->
        case Regex.run(~r/VmRSS:\s+(\d+)/, status) do
          [_, kb] -> String.to_integer(kb)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp normalize_argv(argv) do
    case Enum.split_while(argv, &(&1 != "--")) do
      {_, ["--" | rest]} -> rest
      {all, _} -> all
    end
  end
end

StateUncompactBench.main()
