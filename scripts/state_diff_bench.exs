# Benchmark / profile Chain.State.difference (the path behind
# "State diff took longer than 1s ... accounts=N").
#
# prepare_state on non-jump blocks does:
#   State.difference(prev_state, block_state)
# which is mostly CAccountMap.difference_full/2 plus light Elixir wrapping
# (decode_storage_diff + storage_root_hash per changed account).
#
# Typical prod warning shape is few changed accounts (e.g. 20) but multi-second
# wall time — difference_full still walks the full account map and, for equal
# nonce/balance/code, recomputes both storage roots (see entries_equal in nif.cpp).
#
# Run from repo root (no full app start):
#   mix run --no-start scripts/state_diff_bench.exs
#   mix run --no-start scripts/state_diff_bench.exs -- --accounts 5000 --changed 20 --slots 8
#   mix run --no-start scripts/state_diff_bench.exs -- --scenario all --warmup 1 --iters 3
#   mix run --no-start scripts/state_diff_bench.exs -- --eprof
#
# Scenarios:
#   live_small_delta     — large live map, mutate K accounts
#   locked_peak_delta    — lock peak then clone+mutate (prepare_state / writer pattern)
#   compact_small_delta  — jump-shaped compact→uncompact peak + small delta (prod hotspot)
#   storage_only_delta   — storage writes only (no nonce bump)
#   fat_storage          — few accounts, huge storage trees (storage-diff dominated)
#   all                  — run every scenario

defmodule StateDiffBench do
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

    accounts = Keyword.get(opts, :accounts, 5_000)
    changed = Keyword.get(opts, :changed, 20)
    slots = Keyword.get(opts, :slots, 8)
    fat_slots = Keyword.get(opts, :fat_slots, 8_000)
    warmup = Keyword.get(opts, :warmup, 1)
    iters = Keyword.get(opts, :iters, 3)
    scenario = Keyword.get(opts, :scenario, "all")
    eprof? = Keyword.get(opts, :eprof, false)
    csv? = Keyword.get(opts, :csv, false)

    _ = CAccountMap.new()

    IO.puts(:stderr, """
    === State.difference bench ===
    accounts=#{accounts} changed=#{changed} slots/account=#{slots} fat_slots=#{fat_slots}
    warmup=#{warmup} iters=#{iters} scenario=#{scenario} eprof=#{eprof?}
    """)

    scenarios =
      case scenario do
        "all" ->
          [
            {:live_small_delta, fn -> build_live_small_delta(accounts, changed, slots) end},
            {:locked_peak_delta, fn -> build_locked_peak_delta(accounts, changed, slots) end},
            {:compact_small_delta, fn -> build_compact_small_delta(accounts, changed, slots) end},
            {:storage_only_delta, fn -> build_storage_only_delta(accounts, changed, slots) end},
            {:fat_storage, fn -> build_fat_storage(min(accounts, 40), changed, fat_slots) end}
          ]

        name ->
          builder =
            case name do
              "live_small_delta" -> fn -> build_live_small_delta(accounts, changed, slots) end
              "locked_peak_delta" -> fn -> build_locked_peak_delta(accounts, changed, slots) end
              "compact_small_delta" -> fn -> build_compact_small_delta(accounts, changed, slots) end
              "compact_vs_live" -> fn -> build_compact_small_delta(accounts, changed, slots) end
              "storage_only_delta" -> fn -> build_storage_only_delta(accounts, changed, slots) end
              "fat_storage" -> fn -> build_fat_storage(min(accounts, 40), changed, fat_slots) end
              other -> raise "unknown --scenario #{inspect(other)}"
            end

          [{String.to_atom(name), builder}]
      end

    if csv? do
      IO.puts(
        "scenario,iter,map_size,changed,nif_ms,elixir_ms,total_ms,delta_accounts,storage_keys,rss_kb"
      )
    end

    Enum.each(scenarios, fn {name, builder} ->
      IO.puts(:stderr, "--- building #{name} ---")
      {build_us, {prev, next}} = :timer.tc(builder)
      map_size = CAccountMap.size(prev.accounts)

      IO.puts(
        :stderr,
        "built #{name} in #{div(build_us, 1000)}ms map_size=#{map_size} rss=#{div(read_rss_kb(), 1024)}MB"
      )

      for _ <- 1..warmup do
        _ = timed_difference(prev, next)
      end

      if eprof? do
        profile_eprof(name, prev, next)
      end

      samples =
        for i <- 1..iters do
          sample = timed_difference(prev, next)
          print_sample(name, i, map_size, sample, csv?)
          sample
        end

      summarize(name, samples)
    end)

    IO.puts(:stderr, """

    Interpretation hints:
    - compact_small_delta nif-dominated with changed << map_size: entries_equal calls
      storage_root_hash_for_entry on every unchanged account, rebuilding a temp Tree from
      compact slots (nif.cpp). Matches "State diff took longer than 1s ... accounts=20".
    - live_small_delta staying fast: live trees use cached root_hash / pointer checks.
    - elixir_ms large: decode_storage_diff + State.difference's per-account storage_root_hash.
    - fat_storage nif-heavy with small map_size: build_storage_diff_list / Tree::difference.
    """)
  end

  defp timed_difference(prev, next) do
    # Single wall-time sample with nested phase timers (avoids nif_ms > total_ms).
    {total_us, {nif_us, elixir_us, result}} =
      :timer.tc(fn ->
        {nif_us, full} =
          :timer.tc(fn ->
            CAccountMap.difference_full(prev.accounts, next.accounts)
          end)

        {elixir_us, result} =
          :timer.tc(fn ->
            Enum.map(full, fn {id, side_a, side_b, state_diff} ->
              report =
                %{}
                |> put_field(:nonce, side_a, side_b)
                |> put_field(:balance, side_a, side_b)
                |> put_field(:code, side_a, side_b)

              storage_map = CAccountMap.decode_storage_diff(state_diff)

              report =
                if map_size(storage_map) > 0 do
                  Map.merge(report, %{
                    state: storage_map,
                    root_hash: {
                      CAccountMap.storage_root_hash(prev.accounts, id),
                      CAccountMap.storage_root_hash(next.accounts, id)
                    }
                  })
                else
                  report
                end

              {id, report}
            end)
          end)

        {nif_us, elixir_us, result}
      end)

    storage_keys =
      Enum.reduce(result, 0, fn {_id, report}, acc ->
        acc + map_size(Map.get(report, :state, %{}))
      end)

    %{
      nif_ms: div(nif_us, 1000),
      elixir_ms: div(elixir_us, 1000),
      total_ms: div(total_us, 1000),
      delta_accounts: length(result),
      storage_keys: storage_keys,
      rss_kb: read_rss_kb()
    }
  end

  defp put_field(report, field, side_a, side_b) do
    a = side_field(side_a, field)
    b = side_field(side_b, field)

    if a == b do
      report
    else
      Map.put(report, field, {a, b})
    end
  end

  defp side_field(nil, :nonce), do: 0
  defp side_field(nil, :balance), do: 0
  defp side_field(nil, :code), do: ""
  defp side_field({nonce, _, _}, :nonce), do: nonce
  defp side_field({_, balance, _}, :balance) when is_integer(balance), do: balance

  defp side_field({_, balance, _}, :balance) when is_binary(balance),
    do: :binary.decode_unsigned(balance)

  defp side_field({_, _, code}, :code), do: code

  defp print_sample(name, i, map_size, sample, true) do
    IO.puts(
      "#{name},#{i},#{map_size},#{sample.delta_accounts},#{sample.nif_ms},#{sample.elixir_ms},#{sample.total_ms},#{sample.delta_accounts},#{sample.storage_keys},#{sample.rss_kb}"
    )
  end

  defp print_sample(name, i, map_size, sample, false) do
    nif_pct =
      if sample.total_ms > 0 do
        Float.round(100.0 * sample.nif_ms / sample.total_ms, 1)
      else
        0.0
      end

    IO.puts(:stderr, """
    #{name} iter=#{i} map_size=#{map_size} changed=#{sample.delta_accounts} storage_keys=#{sample.storage_keys}
      nif_ms=#{sample.nif_ms} elixir_ms=#{sample.elixir_ms} total_ms=#{sample.total_ms} (nif=#{nif_pct}%)
      rss_mb=#{div(sample.rss_kb, 1024)}
    """)
  end

  defp summarize(name, samples) do
    n = length(samples)
    avg = fn key -> div(Enum.sum(Enum.map(samples, &Map.fetch!(&1, key))), n) end

    IO.puts(
      :stderr,
      "SUMMARY #{name} avg_nif_ms=#{avg.(:nif_ms)} avg_elixir_ms=#{avg.(:elixir_ms)} " <>
        "avg_total_ms=#{avg.(:total_ms)} changed=#{hd(samples).delta_accounts}"
    )
  end

  defp profile_eprof(name, prev, next) do
    IO.puts(:stderr, "eprof #{name} (State.difference)...")
    :eprof.start()
    :eprof.profile(fn -> State.difference(prev, next) end)
    :eprof.analyze(:total)
    :eprof.stop()
  end

  # --- builders (prepare_state-shaped) ---

  defp build_live_small_delta(n, changed, slots) do
    prev = build_live_state(n, slots)
    next = mutate(prev, changed, slots)
    {prev, next}
  end

  defp build_locked_peak_delta(n, changed, slots) do
    peak = build_live_state(n, slots) |> State.normalize() |> State.lock()
    next = mutate(peak, changed, slots)
    {peak, next}
  end

  # Jump-block shaped: uncompact leaves compact_storage slots; unchanged accounts
  # pay storage_root_hash_for_entry by rebuilding a temp Tree from every slot
  # (nif.cpp entries_equal). This is the usual multi-second / few-account warning.
  defp build_compact_small_delta(n, changed, slots) do
    peak = build_live_state(n, slots) |> State.normalize() |> State.lock()
    prev = peak |> State.compact() |> State.uncompact() |> State.lock()
    next = mutate(prev, changed, slots)
    {prev, next}
  end

  # Storage-only mutations (no nonce bump) so changed rows also go through
  # storage root comparison inside entries_equal.
  defp build_storage_only_delta(n, changed, slots) do
    prev = build_live_state(n, slots) |> State.normalize() |> State.lock()

    next =
      prev
      |> State.clone()
      |> then(fn st ->
        Enum.reduce(1..changed, st, fn i, acc ->
          id = addr(i)

          updates =
            for s <- 1..max(div(slots, 4), 1), into: %{} do
              {slot(i * 10_000 + s), <<i * 999 + s::unsigned-size(256)>>}
            end

          State.storage_put_map(acc, %{id => updates})
        end)
      end)
      |> State.normalize()

    {prev, next}
  end

  defp build_fat_storage(n, changed, fat_slots) do
    prev = build_live_state(n, fat_slots)
    next = mutate(prev, min(changed, n), fat_slots)
    {prev, next}
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
    |> State.normalize()
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

        # Bump nonce so changed rows exit entries_equal early; unchanged rows still
        # pay storage_root_hash_for_entry across the full map (the prod hotspot).
        acc = State.storage_put_map(acc, %{id => updates})
        meta = State.ensure_account(acc, id)
        State.set_account(acc, id, %{meta | nonce: meta.nonce + 1})
      end)
    end)
    |> State.normalize()
  end

  defp addr(i), do: <<i::unsigned-size(160)>>
  defp slot(i), do: <<i::unsigned-size(256)>>

  defp normalize_argv(argv) do
    case argv do
      ["--" | rest] -> rest
      other -> other
    end
  end

  defp read_rss_kb do
    case File.read("/proc/self/status") do
      {:ok, body} ->
        case Regex.run(~r/^VmRSS:\s+(\d+)\s+kB/m, body) do
          [_, n] -> String.to_integer(n)
          _ -> 0
        end

      _ ->
        0
    end
  end
end

StateDiffBench.main(System.argv())
