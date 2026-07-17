# Benchmark ChainSql state(delta:…) — the path behind prod
#   "state(delta:0x...) took Nms"
# in Model.ChainSql.state/1 for non-jump blocks.
#
# Non-jump blocks store {jump_hash, difference(jump_state, block_state)}. do_state:
#   jump = EtsLru.fetch(JumpState, …)   # often cached
#   jump |> State.clone() |> State.apply_difference(delta) |> State.normalize()
# Warns when wall time > 2s.
#
# This bench times the clone + apply_difference + normalize segment (cached jump).
#
# Run from repo root (no full app start):
#   mix run --no-start scripts/state_delta_apply_bench.exs
#   mix run --no-start scripts/state_delta_apply_bench.exs -- --accounts 14000 --changed 20
#   mix run --no-start scripts/state_delta_apply_bench.exs -- --scenario all --warmup 1 --iters 3
#   mix run --no-start scripts/state_delta_apply_bench.exs -- --eprof
#
# Scenarios:
#   small_delta       — jump peak + few changed accounts (common block)
#   medium_delta      — hundreds of changed accounts
#   large_delta       — thousands of changed accounts (near ChainSql >10k bug threshold)
#   storage_heavy     — few accounts, fat storage key deltas
#   cold_jump_uncompact — uncompact jump then apply (JumpState cache miss proxy)
#   all               — run every scenario

defmodule StateDeltaApplyBench do
  @moduledoc false

  alias Chain.State

  def main(argv \\ System.argv()) do
    argv = normalize_argv(argv)

    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          accounts: :integer,
          changed: :integer,
          slots: :integer,
          fat_slots: :integer,
          warmup: :integer,
          iters: :integer,
          scenario: :string,
          eprof: :boolean,
          csv: :boolean
        ]
      )

    accounts = Keyword.get(opts, :accounts, 14_000)
    changed = Keyword.get(opts, :changed, 20)
    slots = Keyword.get(opts, :slots, 8)
    fat_slots = Keyword.get(opts, :fat_slots, 2_000)
    warmup = Keyword.get(opts, :warmup, 1)
    iters = Keyword.get(opts, :iters, 3)
    scenario = Keyword.get(opts, :scenario, "all")
    eprof? = Keyword.get(opts, :eprof, false)
    csv? = Keyword.get(opts, :csv, false)

    _ = CAccountMap.new()

    IO.puts(:stderr, """
    === State delta-apply bench (ChainSql state(delta:…)) ===
    accounts=#{accounts} changed=#{changed} slots/account=#{slots} fat_slots=#{fat_slots}
    warmup=#{warmup} iters=#{iters} scenario=#{scenario} eprof=#{eprof?}
    """)

    scenarios =
      case scenario do
        "all" ->
          [
            {:small_delta, fn -> build_delta_case(accounts, changed, slots, :live) end},
            {:medium_delta,
             fn -> build_delta_case(accounts, min(changed * 10, accounts), slots, :live) end},
            {:large_delta,
             fn -> build_delta_case(accounts, min(2_000, accounts), slots, :live) end},
            {:storage_heavy,
             fn -> build_delta_case(min(accounts, 40), min(changed, 20), fat_slots, :live) end},
            {:cold_jump_uncompact,
             fn -> build_delta_case(accounts, changed, slots, :from_compact) end}
          ]

        name ->
          builder =
            case name do
              "small_delta" ->
                fn -> build_delta_case(accounts, changed, slots, :live) end

              "medium_delta" ->
                fn -> build_delta_case(accounts, min(changed * 10, accounts), slots, :live) end

              "large_delta" ->
                fn -> build_delta_case(accounts, min(2_000, accounts), slots, :live) end

              "storage_heavy" ->
                fn -> build_delta_case(min(accounts, 40), min(changed, 20), fat_slots, :live) end

              "cold_jump_uncompact" ->
                fn -> build_delta_case(accounts, changed, slots, :from_compact) end

              other ->
                raise "unknown --scenario #{inspect(other)}"
            end

          [{String.to_atom(name), builder}]
      end

    if csv? do
      IO.puts(
        "scenario,iter,map_size,delta_accounts,storage_keys,clone_ms,apply_ms,normalize_ms,uncompact_ms,total_ms,rss_kb"
      )
    end

    Enum.each(scenarios, fn {name, builder} ->
      IO.puts(:stderr, "--- building #{name} ---")
      {build_us, fixture} = :timer.tc(builder)
      map_size = CAccountMap.size(fixture.base.accounts)

      IO.puts(
        :stderr,
        "built #{name} in #{div(build_us, 1000)}ms map_size=#{map_size} " <>
          "delta_accounts=#{length(fixture.delta)} rss=#{div(read_rss_kb(), 1024)}MB"
      )

      for _ <- 1..warmup do
        _ = timed_delta_apply(fixture)
      end

      if eprof? do
        profile_eprof(name, fixture)
      end

      samples =
        for i <- 1..iters do
          sample = timed_delta_apply(fixture)
          print_sample(name, i, map_size, sample, csv?)
          sample
        end

      summarize(name, samples)
    end)

    IO.puts(:stderr, """

    Interpretation hints:
    - Matches Model.ChainSql.do_state for {prev_hash, delta} rows (JumpState hit).
    - Prod warning fires at >2000ms total for clone+apply+normalize.
    - cold_jump_uncompact adds uncompact_ms (JumpState miss proxy).
    - apply_ms dominates when delta_accounts or storage_keys is large.
    - large_delta approaches the ChainSql length(delta)>10_000 recompress trigger.
    """)
  end

  defp timed_delta_apply(%{base: base, delta: delta, compact_jump: nil}) do
    do_timed_apply(base, delta, 0)
  end

  defp timed_delta_apply(%{base: _base, delta: delta, compact_jump: compact}) do
    {uncompact_us, jump} =
      :timer.tc(fn ->
        State.uncompact(compact) |> State.lock()
      end)

    sample = do_timed_apply(jump, delta, div(uncompact_us, 1000))
    %{sample | total_ms: sample.total_ms + sample.uncompact_ms}
  end

  defp do_timed_apply(base, delta, uncompact_ms) do
    {total_us, {clone_us, apply_us, normalize_us, result}} =
      :timer.tc(fn ->
        {clone_us, cloned} = :timer.tc(fn -> State.clone(base) end)

        {apply_us, applied} =
          :timer.tc(fn ->
            State.apply_difference(cloned, delta)
          end)

        {normalize_us, normalized} =
          :timer.tc(fn ->
            State.normalize(applied)
          end)

        {clone_us, apply_us, normalize_us, normalized}
      end)

    storage_keys =
      Enum.reduce(delta, 0, fn {_id, report}, acc ->
        acc + map_size(Map.get(report, :state, %{}))
      end)

    %{
      delta_accounts: length(delta),
      storage_keys: storage_keys,
      clone_ms: div(clone_us, 1000),
      apply_ms: div(apply_us, 1000),
      normalize_ms: div(normalize_us, 1000),
      uncompact_ms: uncompact_ms,
      total_ms: div(total_us, 1000) + uncompact_ms,
      hash: result.hash,
      rss_kb: read_rss_kb()
    }
  end

  defp print_sample(name, i, map_size, sample, true) do
    IO.puts(
      "#{name},#{i},#{map_size},#{sample.delta_accounts},#{sample.storage_keys}," <>
        "#{sample.clone_ms},#{sample.apply_ms},#{sample.normalize_ms},#{sample.uncompact_ms}," <>
        "#{sample.total_ms},#{sample.rss_kb}"
    )
  end

  defp print_sample(name, i, map_size, sample, false) do
    IO.puts(:stderr, """
    #{name} iter=#{i} map_size=#{map_size} delta_accounts=#{sample.delta_accounts} storage_keys=#{sample.storage_keys}
      clone_ms=#{sample.clone_ms} apply_ms=#{sample.apply_ms} normalize_ms=#{sample.normalize_ms} uncompact_ms=#{sample.uncompact_ms}
      total_ms=#{sample.total_ms} rss_mb=#{div(sample.rss_kb, 1024)}
    """)
  end

  defp summarize(name, samples) do
    n = length(samples)
    avg = fn key -> div(Enum.sum(Enum.map(samples, &Map.fetch!(&1, key))), n) end

    IO.puts(
      :stderr,
      "SUMMARY #{name} avg_total_ms=#{avg.(:total_ms)} avg_apply_ms=#{avg.(:apply_ms)} " <>
        "avg_clone_ms=#{avg.(:clone_ms)} avg_normalize_ms=#{avg.(:normalize_ms)} " <>
        "avg_uncompact_ms=#{avg.(:uncompact_ms)} delta_accounts=#{hd(samples).delta_accounts}"
    )
  end

  defp profile_eprof(name, %{base: base, delta: delta, compact_jump: nil}) do
    IO.puts(:stderr, "eprof #{name} (clone+apply+normalize)...")
    :eprof.start()

    :eprof.profile(fn ->
      base |> State.clone() |> State.apply_difference(delta) |> State.normalize()
    end)

    :eprof.analyze(:total)
    :eprof.stop()
  end

  defp profile_eprof(name, fixture) do
    profile_eprof(name, %{
      fixture
      | compact_jump: nil,
        base: State.uncompact(fixture.compact_jump)
    })
  end

  # mode :live — base is already an uncompacted/locked peak (JumpState hit)
  # mode :from_compact — keep compact jump aside; each sample uncompacts first
  defp build_delta_case(n, changed, slots, mode) do
    live = build_live_state(n, slots) |> State.normalize() |> State.lock()
    compact = State.compact(live)

    base =
      case mode do
        :live -> live |> State.compact() |> State.uncompact() |> State.lock()
        :from_compact -> nil
      end

    working =
      case mode do
        :live -> base
        :from_compact -> State.uncompact(compact) |> State.lock()
      end

    next = mutate(working, changed, slots)
    delta = State.difference(working, next)

    %{
      base: working,
      delta: delta,
      compact_jump: if(mode == :from_compact, do: compact, else: nil)
    }
  end

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

  defp mutate(state, changed, slots_per) do
    state
    |> State.clone()
    |> then(fn st ->
      Enum.reduce(1..changed, st, fn i, acc ->
        id = addr(i)

        updates =
          for s <- 1..max(div(slots_per, 4), 1), into: %{} do
            {slot(i * 10_000 + s), <<i * 999 + s::unsigned-size(256)>>}
          end

        acc = State.storage_put_map(acc, %{id => updates})
        meta = State.ensure_account(acc, id)
        State.set_account(acc, id, %{meta | nonce: meta.nonce + 1})
      end)
    end)
    |> State.normalize()
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

StateDeltaApplyBench.main()
