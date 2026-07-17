# CAccountMap / Chain.State — parallel concurrency stress.
#
# Hammers account-map NIFs from many Tasks: map mutexes, storage COW,
# difference_full dual-lock order, compact/uncompact, and State.lock/clone.
#
# Thread Sanitizer (not ASan): rebuild the NIF with -fsanitize=thread and run
# this script the same way as ASan (swap priv/merkletree_nif.so). TSan + BEAM can be noisy.
#
# Run:
#   mix run --no-start scripts/cmerkle_parallel_stress.exs -- --waves 3 --tasks 48
#
# Options:
#   --tasks N     concurrent Task.async_stream workers per wave (default: 32)
#   --waves N     repeat full suite this many times (default: 2)
#   --ops N       operations per worker in same-tree scenarios (default: 40)
#   --seed N      RNG seed
#   --accounts N  account count for map scenarios (default: 200)
#   --scenario PX run only scenario PX (e.g. P12); repeat for multiple
#
# Exit 0 if all waves complete. Native crashes are not caught in Elixir.

defmodule CMerkleParallelStress do
  @moduledoc false

  alias Chain.{Account, State}

  # --- Theory map (for triage notes) ---
  #
  # P12 account_map uncompact_state + difference_full workers (D-C2, D-D3)
  # P13 account_map clone/put/delete + storage APIs (D-C1, D-C4)
  # P14 Chain.State difference + lock + uncompact + lock→clone→write composite (D-D1–D-D4)
  # P15 dirty-scheduler saturation: lock, difference_full, uncompact, storage
  # P16 concurrent State.lock on compact states (block-sync memory path)
  # P17 prepare_state pipeline (native diff + lock + to_list)
  # P18 writer sim / P18L clone eth_call
  # P19 large map small delta
  # P20 dirty saturation + difference_full
  #

  @all_scenarios ~w(P12 P13 P14 P15 P16 P17 P18 P18L P19 P20)

  def normalize_argv(argv) do
    case argv do
      ["--" | rest] -> rest
      other -> other
    end
  end

  def main(argv) do
    argv = normalize_argv(argv)

    {opts, _} =
      OptionParser.parse!(argv,
        strict: [
          tasks: :integer,
          waves: :integer,
          ops: :integer,
          seed: :integer,
          accounts: :integer,
          scenario: :keep
        ]
      )

    tasks = Keyword.get(opts, :tasks, 32)
    waves = Keyword.get(opts, :waves, 2)
    ops = Keyword.get(opts, :ops, 40)
    accounts = Keyword.get(opts, :accounts, 200)

    scenarios =
      case Keyword.get_values(opts, :scenario) do
        [] -> @all_scenarios
        names -> Enum.map(names, &normalize_scenario/1)
      end

    seed =
      Keyword.get(opts, :seed) ||
        case System.get_env("MERKLE_PARALLEL_SEED") do
          nil -> 20_260_416
          "" -> 20_260_416
          s -> String.to_integer(String.trim(s))
        end

    :rand.seed(:exsss, {seed, seed, seed})

    IO.puts(:stderr, """
    === CAccountMap parallel stress ===
    otp=#{System.otp_release()} elixir=#{System.version()} schedulers=#{System.schedulers_online()}
    seed=#{seed} tasks=#{tasks} waves=#{waves} ops_per_task=#{ops} accounts=#{accounts}
    scenarios=#{Enum.join(scenarios, ",")}
    """)

    ctx = %{tasks: tasks, ops: ops, seed: seed, accounts: accounts}

    Enum.each(1..waves, fn w ->
      IO.puts(:stderr, "--- wave #{w}/#{waves} ---")

      for name <- scenarios do
        run_scenario(name, ctx)
      end

      IO.puts(:stderr, "WAVE_OK #{w}")
    end)

    IO.puts(:stderr, "=== parallel stress finished (Elixir layer); exit 0 ===")
  end

  defp normalize_scenario("P" <> n), do: "P" <> n
  defp normalize_scenario(other), do: String.upcase(other)

  defp run_scenario(name, ctx) do
    case name do
      "P12" ->
        run_named("P12_uncompact_and_diff", fn -> p12_uncompact_and_diff(ctx) end)

      "P13" ->
        run_named("P13_account_map_contention", fn -> p13_account_map_contention(ctx) end)

      "P14" ->
        run_named("P14_block_sync_composite", fn -> p14_block_sync_composite(ctx) end)

      "P15" ->
        run_named("P15_dirty_scheduler_saturation", fn -> p15_dirty_scheduler_saturation(ctx) end)

      "P16" ->
        run_named("P16_block_lock_memory", fn -> p16_block_lock_memory(ctx) end)

      "P17" ->
        run_named("P17_prepare_state_pipeline", fn -> p17_prepare_state_pipeline(ctx) end)

      "P18" ->
        run_named("P18_writer_sim", fn -> p18_writer_sim(ctx) end)

      "P18L" ->
        run_named("P18_clone_eth_call", fn -> p18_clone_eth_call(ctx) end)

      "P19" ->
        run_named("P19_large_map_small_delta", fn -> p19_large_map_small_delta(ctx) end)

      "P20" ->
        run_named("P20_dirty_saturation_diff", fn -> p20_dirty_saturation_diff(ctx) end)

      other ->
        raise("unknown scenario #{inspect(other)}")
    end
  end

  defp run_named(name, fun) do
    t0 = System.monotonic_time(:millisecond)

    try do
      fun.()
      dt = System.monotonic_time(:millisecond) - t0
      IO.puts(:stderr, "PARALLEL_OK #{name} #{dt}ms")
    catch
      kind, reason ->
        IO.puts(:stderr, "PARALLEL_FAIL #{name} kind=#{inspect(kind)} reason=#{inspect(reason)}")
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp slot(i), do: <<i::unsigned-size(256)>>

  defp storage_list(i, mult \\ 5) do
    [{slot(i), <<i * mult::unsigned-size(256)>>}]
  end

  defp build_compact_accounts(n) do
    Enum.reduce(1..n, State.new(), fn i, st ->
      acc = %Account{
        nonce: i,
        balance: i * 1_000,
        storage_root: storage_list(i),
        code: <<i>>,
        map_backed: false
      }

      State.set_account(st, addr(i), acc)
    end)
    |> State.compact()
    |> Map.fetch!(:accounts)
  end

  defp build_live_state(n) do
    Enum.reduce(1..n, State.new(), fn i, st ->
      acc = %Account{
        nonce: i,
        balance: i * 1_000,
        storage_root: [
          {slot(i), <<i * 3::unsigned-size(256)>>},
          {slot(i + 10_000), <<i + 1::unsigned-size(256)>>}
        ],
        code: <<i>>,
        map_backed: false
      }

      State.set_account(st, addr(i), acc)
    end)
  end

  defp p12_uncompact_and_diff(%{tasks: tasks, accounts: n}) do
    compact = build_compact_accounts(n)
    workers = div(tasks, 2) |> max(1)
    uncompact_workers = tasks - workers

    uncompact_f = fn ->
      Task.async_stream(
        1..uncompact_workers,
        fn _ ->
          {accounts, _hash} = CAccountMap.uncompact_state(compact)
          CAccountMap.size(accounts)
        end,
        max_concurrency: uncompact_workers,
        timeout: :infinity,
        ordered: false
      )
      |> Stream.run()
    end

    diff_f = fn ->
      Task.async_stream(
        1..workers,
        fn i ->
          a =
            Enum.reduce(1..(8 + rem(i, 5)), CAccountMap.new(), fn j, acc ->
              CAccountMap.put(
                acc,
                addr(j),
                j,
                j * 100,
                [{slot(j), <<j + i::unsigned-size(256)>>}],
                <<j>>
              )
            end)

          b =
            a
            |> CAccountMap.clone()
            |> CAccountMap.storage_put_map(%{
              addr(1) => %{slot(i + 9000) => <<i + 2::unsigned-size(256)>>}
            })

          CAccountMap.difference_full(a, b)
        end,
        max_concurrency: workers,
        timeout: :infinity,
        ordered: false
      )
      |> Stream.run()
    end

    diff_f.()
    uncompact_f.()
    diff_f.()
  end

  defp p13_account_map_contention(%{tasks: tasks, ops: ops}) do
    n = min(tasks, 80)
    compact = build_compact_accounts(n)
    {base, _hash} = CAccountMap.uncompact_state(compact)

    1..tasks
    |> Task.async_stream(
      fn w ->
        Enum.each(1..ops, fn j ->
          case rem(w + j, 5) do
            0 ->
              fork = CAccountMap.clone(base)
              new_storage = [{slot(w + j), <<j::unsigned-size(256)>>}]
              _ = CAccountMap.put(fork, addr(rem(w, n) + 1), j, j * 100, new_storage, <<j>>)

            1 ->
              id = addr(rem(w, n) + 1)
              _ = CAccountMap.storage_root_hash(base, id)
              _ = CAccountMap.storage_to_list(base, id)
              _ = CAccountMap.storage_get(base, id, slot(w + j + 50_000))

            2 ->
              fork = CAccountMap.clone(base)
              _ = CAccountMap.delete(fork, addr(rem(w + j, n) + 1))

            _ ->
              _ = CAccountMap.to_list(base)
          end
        end)

        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p14_block_sync_composite(%{tasks: tasks, accounts: n, ops: ops}) do
    prev = build_live_state(n)

    block =
      prev
      |> State.clone()
      |> then(fn st ->
        Enum.reduce(1..min(ops, n), st, fn i, acc ->
          id = addr(rem(i, n) + 1)

          State.storage_put_map(acc, %{
            id => %{slot(i + 100_000) => <<i * 11::unsigned-size(256)>>}
          })
        end)
      end)

    compact = State.compact(block)
    quarter = div(tasks, 4) |> max(1)
    differ = quarter
    lockers = quarter
    writers = quarter
    uncompactors = max(tasks - differ - lockers - writers, 1)

    run = fn tag, count, fun ->
      Task.async_stream(
        1..count,
        fun,
        max_concurrency: count,
        timeout: :infinity,
        ordered: false
      )
      |> Stream.run()

      IO.puts(:stderr, "P14_#{tag}_done")
    end

    run.(:diff, differ, fn _ ->
      _ = State.difference(prev, block)
      :ok
    end)

    run.(:lock, lockers, fn _ ->
      _ = State.lock(State.clone(block))
      :ok
    end)

    run.(:write, writers, fn w ->
      locked = State.lock(prev)
      fork = State.clone(locked)
      id = addr(rem(w, n) + 1)

      fork =
        State.storage_put_map(fork, %{
          id => %{slot(w + 300_000) => <<w * 13::unsigned-size(256)>>}
        })

      _ = State.hash(fork)
      :ok
    end)

    run.(:uncompact, uncompactors, fn _ ->
      _ = State.uncompact(compact)
      :ok
    end)
  end

  defp p15_dirty_scheduler_saturation(%{tasks: tasks, accounts: n}) do
    compact = build_compact_accounts(min(n, 120))
    live = build_live_state(min(n, 80)) |> State.normalize()

    other =
      live
      |> State.clone()
      |> then(fn st ->
        State.set_account(st, addr(1), %Account{
          nonce: 999,
          balance: 999,
          storage_root: [],
          code: <<>>,
          map_backed: false
        })
      end)

    1..tasks
    |> Task.async_stream(
      fn w ->
        case rem(w, 5) do
          0 ->
            _ = CAccountMap.lock(live.accounts)

          1 ->
            _ = CAccountMap.storage_root_hash(live.accounts, addr(1))
            _ = CAccountMap.storage_root_hash(other.accounts, addr(1))
            _ = CAccountMap.storage_to_list(live.accounts, addr(1))

          2 ->
            _ = CAccountMap.uncompact_state(compact)

          3 ->
            _ = CAccountMap.difference_full(live.accounts, other.accounts)

          _ ->
            _ = CAccountMap.to_list(live.accounts)
        end

        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p16_block_lock_memory(%{tasks: tasks, accounts: n, ops: ops}) do
    prev = build_live_state(n)

    block =
      prev
      |> State.clone()
      |> then(fn st ->
        Enum.reduce(1..min(ops, n), st, fn i, acc ->
          id = addr(rem(i, n) + 1)

          State.storage_put_map(acc, %{
            id => %{slot(i + 300_000) => <<i * 17::unsigned-size(256)>>}
          })
        end)
      end)

    compact = State.compact(block)

    1..tasks
    |> Task.async_stream(
      fn _ ->
        restored =
          compact
          |> State.uncompact()
          |> State.normalize()

        _ = State.lock(restored)
        _ = State.lock(State.clone(restored))
        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    {_locked, orphans, _shared, _res} = CMerkleTree.nif_stats()

    if orphans > 0 do
      raise("P16 pending orphans=#{orphans}")
    end
  end

  defp p17_prepare_state_pipeline(%{tasks: tasks, accounts: n, ops: ops}) do
    prev = build_live_state(n)

    block =
      prev
      |> State.clone()
      |> then(fn st ->
        Enum.reduce(1..min(ops, n), st, fn i, acc ->
          id = addr(rem(i, n) + 1)

          State.storage_put_map(acc, %{
            id => %{slot(i + 100_000) => <<i * 11::unsigned-size(256)>>}
          })
        end)
      end)

    quarter = div(tasks, 4) |> max(1)
    differ = quarter
    lockers = quarter
    legacy = quarter
    native = max(tasks - differ - lockers - legacy, 1)

    run = fn tag, count, fun ->
      Task.async_stream(1..count, fun, max_concurrency: count, timeout: :infinity, ordered: false)
      |> Stream.run()

      IO.puts(:stderr, "P17_#{tag}_done")
    end

    run.(:diff, differ, fn _ -> State.difference(prev, block) end)
    run.(:lock, lockers, fn _ -> State.lock(State.clone(block)) end)
    run.(:legacy, legacy, fn _ -> CAccountMap.to_list(block.accounts) end)
    run.(:native, native, fn _ -> CAccountMap.difference_full(prev.accounts, block.accounts) end)
  end

  defp p18_writer_sim(%{tasks: tasks, accounts: n}) do
    prev = build_live_state(n)

    block =
      prev
      |> State.clone()
      |> State.storage_put_map(%{
        addr(1) => %{slot(400_000) => <<400_000::unsigned-size(256)>>}
      })

    writer =
      Task.async(fn ->
        for _ <- 1..20 do
          _ = State.difference(prev, block)
        end
      end)

    1..max(tasks - 1, 1)
    |> Task.async_stream(
      fn w ->
        map = block.accounts

        case rem(w, 4) do
          0 ->
            _ = CAccountMap.lock(map)

          1 ->
            _ = CAccountMap.to_list(map)

          2 ->
            _ = CAccountMap.storage_root_hash(map, addr(1))
            _ = CAccountMap.storage_root_hash(map, addr(rem(w, n) + 1))
            _ = CAccountMap.storage_to_list(map, addr(1))

          _ ->
            _ = CAccountMap.delete(CAccountMap.clone(map), addr(rem(w, n) + 1))
        end

        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    Task.await(writer, :infinity)
  end

  defp p18_clone_eth_call(%{tasks: tasks, accounts: n}) do
    base = build_live_state(max(n, 50))

    1..tasks
    |> Task.async_stream(
      fn w ->
        id = addr(rem(w, max(n, 50)) + 1)

        fork =
          base
          |> State.clone()
          |> State.storage_put_map([{id, [{slot(900_000 + w), <<w::unsigned-size(256)>>}]}])

        _ = State.hash(fork)
        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p19_large_map_small_delta(%{tasks: tasks}) do
    n = 400
    base = build_live_state(n)

    block =
      base
      |> State.clone()
      |> then(fn st ->
        Enum.reduce(1..5, st, fn i, acc ->
          id = addr(i)

          State.storage_put_map(acc, %{
            id => %{slot(i + 500_000) => <<i * 13::unsigned-size(256)>>}
          })
        end)
      end)

    workers = min(tasks, 48)

    1..workers
    |> Task.async_stream(
      fn _ -> State.difference(base, block) end,
      max_concurrency: workers,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p20_dirty_saturation_diff(%{tasks: tasks, accounts: n}) do
    live = build_live_state(min(n, 80))

    other =
      live
      |> State.clone()
      |> then(fn st ->
        State.set_account(st, addr(1), %Account{
          nonce: 999,
          balance: 999,
          storage_root: [],
          code: <<>>,
          map_backed: false
        })
      end)

    map = live.accounts

    1..tasks
    |> Task.async_stream(
      fn w ->
        case rem(w, 5) do
          0 ->
            _ = CAccountMap.difference_full(map, other.accounts)

          1 ->
            _ = CAccountMap.lock(map)

          2 ->
            _ = State.difference(live, other)

          3 ->
            _ = CAccountMap.storage_root_hash(live.accounts, addr(1))
            _ = CAccountMap.storage_root_hash(other.accounts, addr(1))
            _ = CAccountMap.storage_to_list(live.accounts, addr(1))

          _ ->
            _ = CAccountMap.to_list(map)
        end

        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end
end

CMerkleParallelStress.main(System.argv())
