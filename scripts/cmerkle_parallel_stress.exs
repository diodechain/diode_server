# CMerkleTree — parallel / concurrency stress (targets live-only failures).
#
# Erlang schedules NIF calls on many schedulers; the NIF uses:
#   - One ErlNifMutex per SharedState (every insert/get/root_hash/difference arm takes Lock(mt))
#   - std::mutex on GlobalStripePool<pair_t> (preallocator.hpp)
#   - A global mutex on LockedStates (enter_lock / leave_lock / resource destructor)
#
# These workloads intentionally hammer the same resource from many Tasks to flush:
#   mutex omissions, refcount/has_clone races, deadlock in difference lock ordering,
#   and pool stripe contention.
#
# Confirmed bug class (parallel clone + insert): COW splits a SharedState so two Trees
# share one ItemPool and one PreAllocator while each Erlang resource still uses its own
# ErlNifMutex — concurrent refcnt / pair slab mutation raced. Fixed in C++ with a
# std::recursive_mutex on ItemPool (see item_pool.cpp) and on PreAllocator
# (preallocator.hpp). Run this script after changes to native trie code.
#
# Thread Sanitizer (not ASan): to hunt data races in C++, rebuild the NIF with
#   -fsanitize=thread
# and run this script the same way as ASan (swap priv/merkletree_nif.so). TSan + BEAM can be noisy.
#
# Run:
#   mix run --no-start scripts/cmerkle_parallel_stress.exs -- --waves 3 --tasks 48
#
# Options:
#   --tasks N     concurrent Task.async_stream workers per wave (default: 32)
#   --waves N     repeat full suite this many times (default: 2)
#   --ops N       operations per worker in same-tree scenarios (default: 40)
#   --seed N      RNG seed
#   --accounts N  account count for P12/P14 (default: 200)
#   --scenario PX run only scenario PX (e.g. P10); repeat for multiple
#
# Exit 0 if all waves complete. Native crashes are not caught in Elixir.

defmodule CMerkleParallelStress do
  @moduledoc false

  alias Chain.{Account, State}

  # --- Theory map (for triage notes) ---
  #
  # P1  Same CMerkleTree ref, concurrent insert/get/root_hash/root_hashes/size —
  #      relies on per-SharedState mutex; would expose missing Lock() on any NIF path.
  #
  # P2  Concurrent difference(ta, tb) identical pair — lock order is by SharedState
  #      address (nif.cpp); should not deadlock; stresses dual-lock hold time.
  #
  # P3  Concurrent difference(ta, tb) vs difference(tb, ta) argument order —
  #      same ordering rule; overlapping waves stress scheduler interleaving.
  #
  # P4  Clone storm: many workers clone same base then mutate (has_clone / make_writeable).
  #
  # P5  Interleaved: half workers mutate T, half run difference(T, U) — contention on first tree.
  #
  # P6  locked_states: concurrent lock/1 on same locked root_hash dedup path (enter_lock).
  #
  # P7  Many disposable trees in parallel — GlobalStripePool take/put under contention.
  #
  # P8  get_proofs + to_list concurrently on same tree — read-heavy + each() traversal.
  #
  # P9  Concurrent lock/1 (enter_lock dedup) + difference/2 on overlapping trees —
  #      reproduces production deadlock: locked_states_mutex held while waiting on a
  #      second tree mutex vs difference_raw dual-lock ordering.
  #
  # P10 leave_lock storm + lock + difference + three-tree overlap (D-A4, D-B2, D-B5)
  # P11 mass disposable trees + GC while difference/lock (D-A2, D-A5)
  # P12 account_map uncompact_state + storage difference workers (D-C2, D-D3)
  # P13 account_map clone/put/delete + storage difference (D-C1, D-C4)
  # P14 Chain.State difference + lock + uncompact + lock→clone→write composite (D-D1–D-D4)
  # P15 dirty-scheduler saturation: lock, difference, uncompact, clone, get_proofs
  # P16 concurrent State.lock on compact states (block-sync memory path)
  #

  @all_scenarios ~w(P1 P2 P3 P4 P5 P6 P7 P8 P9 P10 P11 P12 P13 P14 P15 P16)

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
    === CMerkleTree parallel stress ===
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
      "P1" ->
        run_named("P1_same_tree_rw", fn -> p1_same_tree_rw(ctx) end)

      "P2" ->
        run_named("P2_concurrent_difference_ab", fn -> p2_concurrent_difference(ctx, :ab) end)

      "P3" ->
        run_named("P3_concurrent_difference_ba", fn -> p2_concurrent_difference(ctx, :ba) end)

      "P4" ->
        run_named("P4_clone_write_storm", fn -> p4_clone_storm(ctx) end)

      "P5" ->
        run_named("P5_interleave_mutate_and_diff", fn -> p5_interleave(ctx) end)

      "P6" ->
        run_named("P6_concurrent_lock", fn -> p6_concurrent_lock(ctx) end)

      "P7" ->
        run_named("P7_many_shortlived_trees", fn -> p7_shortlived_parallel(ctx) end)

      "P8" ->
        run_named("P8_proofs_and_to_list", fn -> p8_proofs_to_list(ctx) end)

      "P9" ->
        run_named("P9_lock_and_difference", fn -> p9_lock_and_difference(ctx) end)

      "P10" ->
        run_named("P10_leave_lock_storm", fn -> p10_leave_lock_storm(ctx) end)

      "P11" ->
        run_named("P11_gc_disposable_trees", fn -> p11_gc_disposable_trees(ctx) end)

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

  defp p1_same_tree_rw(%{tasks: tasks, ops: ops}) do
    seed_items =
      Enum.map(1..50, fn i ->
        {String.pad_leading("p1#{i}", 32), CMerkleTree.hash("seed#{i}")}
      end)

    tree = CMerkleTree.new() |> CMerkleTree.insert_items(seed_items)

    1..tasks
    |> Task.async_stream(
      fn w ->
        Enum.each(1..ops, fn j ->
          k = rem(w * 997 + j * 31, 400)
          key = String.pad_leading("pk#{k}", 32)
          tree = CMerkleTree.insert(tree, key, CMerkleTree.hash("v#{w}#{j}"))
          _ = CMerkleTree.get(tree, key)
          _ = CMerkleTree.root_hash(tree)
          _ = CMerkleTree.size(tree)
          _ = CMerkleTree.root_hashes(tree)
        end)

        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p2_concurrent_difference(%{tasks: tasks}, order) do
    a =
      Enum.map(1..120, fn i ->
        {String.pad_leading("da#{i}", 32), CMerkleTree.hash("da#{i}")}
      end)

    b =
      Enum.map(1..120, fn i ->
        {String.pad_leading("db#{i}", 32), CMerkleTree.hash("db#{i}")}
      end)

    ta = CMerkleTree.new() |> CMerkleTree.insert_items(a)
    tb = CMerkleTree.new() |> CMerkleTree.insert_items(b)

    1..tasks
    |> Task.async_stream(
      fn _ ->
        _ =
          case order do
            :ab -> CMerkleTree.difference(ta, tb)
            :ba -> CMerkleTree.difference(tb, ta)
          end

        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p4_clone_storm(%{tasks: tasks, ops: ops}) do
    base =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..80, fn i -> {String.pad_leading("b#{i}", 32), CMerkleTree.hash("b#{i}")} end)
      )

    1..tasks
    |> Task.async_stream(
      fn w ->
        Enum.reduce(1..ops, CMerkleTree.clone(base), fn j, acc ->
          CMerkleTree.insert(
            acc,
            String.pad_leading("c#{w}_#{j}", 32),
            CMerkleTree.hash("x#{w}#{j}")
          )
        end)

        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p5_interleave(%{tasks: tasks, ops: ops}) do
    ta =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..100, fn i ->
          {String.pad_leading("ia#{i}", 32), CMerkleTree.hash("ia#{i}")}
        end)
      )

    tb =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..100, fn i ->
          {String.pad_leading("ib#{i}", 32), CMerkleTree.hash("ib#{i}")}
        end)
      )

    mutators = div(tasks, 2) |> max(1)
    differ = tasks - mutators

    step = fn tag ->
      Task.async_stream(
        1..mutators,
        fn w ->
          Enum.each(1..ops, fn j ->
            k = String.pad_leading("m#{tag}#{w}_#{j}", 32)
            _ = CMerkleTree.insert(ta, k, CMerkleTree.hash("mut#{w}#{j}"))
          end)

          :ok
        end,
        max_concurrency: mutators,
        timeout: :infinity,
        ordered: false
      )
      |> Stream.run()
    end

    diff_f = fn ->
      Task.async_stream(
        1..differ,
        fn _ ->
          _ = CMerkleTree.difference(ta, tb)
          :ok
        end,
        max_concurrency: differ,
        timeout: :infinity,
        ordered: false
      )
      |> Stream.run()
    end

    # Interleave: waves of concurrent diff with concurrent mutators
    step.(:a)
    diff_f.()
    step.(:b)
    diff_f.()
  end

  defp p6_concurrent_lock(%{tasks: tasks}) do
    data =
      Enum.map(1..60, fn i -> {String.pad_leading("L#{i}", 32), CMerkleTree.hash("L#{i}")} end)

    base = CMerkleTree.new() |> CMerkleTree.insert_items(data)

    1..tasks
    |> Task.async_stream(
      fn _ ->
        _ =
          base
          |> CMerkleTree.clone()
          |> CMerkleTree.lock()

        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p9_lock_and_difference(%{tasks: tasks, ops: ops}) do
    shared =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..100, fn i -> {String.pad_leading("s#{i}", 32), CMerkleTree.hash("s#{i}")} end)
      )

    other =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..100, fn i -> {String.pad_leading("o#{i}", 32), CMerkleTree.hash("o#{i}")} end)
      )

    lockers = div(tasks, 3) |> max(1)
    differ = tasks - lockers

    Task.async_stream(
      1..lockers,
      fn _ ->
        _ =
          shared
          |> CMerkleTree.clone()
          |> CMerkleTree.lock()

        :ok
      end,
      max_concurrency: lockers,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    Task.async_stream(
      1..differ,
      fn w ->
        Enum.each(1..ops, fn j ->
          k = String.pad_leading("p9#{w}_#{j}", 32)
          _ = CMerkleTree.insert(shared, k, CMerkleTree.hash("p9#{w}#{j}"))
          _ = CMerkleTree.difference(shared, other)
          _ = CMerkleTree.difference(other, shared)
        end)

        :ok
      end,
      max_concurrency: differ,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p7_shortlived_parallel(%{tasks: tasks}) do
    1..tasks
    |> Task.async_stream(
      fn w ->
        items =
          Enum.map(1..25, fn j ->
            {String.pad_leading("s#{w}_#{j}", 32), CMerkleTree.hash("s#{w}_#{j}")}
          end)

        t = CMerkleTree.new() |> CMerkleTree.insert_items(items)
        _ = CMerkleTree.root_hash(t)
        _ = CMerkleTree.bucket_count(t)
        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p8_proofs_to_list(%{tasks: tasks, ops: ops}) do
    keys = Enum.map(1..80, fn i -> String.pad_leading("h#{i}", 32) end)

    tree =
      Enum.reduce(keys, CMerkleTree.new(), fn k, acc ->
        CMerkleTree.insert(acc, k, CMerkleTree.hash(k))
      end)

    1..tasks
    |> Task.async_stream(
      fn w ->
        Enum.each(1..ops, fn j ->
          k = Enum.at(keys, rem(w + j, length(keys)))
          _ = CMerkleTree.get_proofs(tree, k)
          _ = CMerkleTree.to_list(tree)
          _ = CMerkleTree.root_hash(tree)
        end)

        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp slot(i), do: <<i::unsigned-size(256)>>

  defp build_compact_accounts(n) do
    for i <- 1..n, into: %{} do
      tree =
        CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i * 5::unsigned-size(256)>>)

      acc = %Account{nonce: i, balance: i * 1_000, storage_root: tree, code: <<i>>}
      {addr(i), Account.compact(acc)}
    end
  end

  defp build_live_state(n) do
    Enum.reduce(1..n, State.new(), fn i, st ->
      tree =
        CMerkleTree.insert_items(CMerkleTree.new(), [
          {slot(i), <<i * 3::unsigned-size(256)>>},
          {slot(i + 10_000), <<i + 1::unsigned-size(256)>>}
        ])

      acc = %Account{nonce: i, balance: i * 1_000, storage_root: tree, code: <<i>>}
      State.set_account(st, addr(i), acc)
    end)
  end

  defp p10_leave_lock_storm(%{tasks: tasks, ops: ops}) do
    shared =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..100, fn i ->
          {String.pad_leading("p10s#{i}", 32), CMerkleTree.hash("p10s#{i}")}
        end)
      )

    tb =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..100, fn i ->
          {String.pad_leading("p10b#{i}", 32), CMerkleTree.hash("p10b#{i}")}
        end)
      )

    tc =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..80, fn i ->
          {String.pad_leading("p10c#{i}", 32), CMerkleTree.hash("p10c#{i}")}
        end)
      )

    third = div(tasks, 4) |> max(1)
    rest = tasks - third

    1..third
    |> Task.async_stream(
      fn w ->
        items =
          Enum.map(1..20, fn j ->
            {String.pad_leading("d#{w}_#{j}", 32), CMerkleTree.hash("d#{w}_#{j}")}
          end)

        _ = CMerkleTree.new() |> CMerkleTree.insert_items(items)
        :ok
      end,
      max_concurrency: third,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    1..rest
    |> Task.async_stream(
      fn w ->
        Enum.each(1..ops, fn j ->
          if rem(w + j, 4) == 0 do
            _ =
              shared
              |> CMerkleTree.clone()
              |> CMerkleTree.lock()
          else
            _ = CMerkleTree.difference(shared, tb)
            _ = CMerkleTree.difference(shared, tc)
            _ = CMerkleTree.difference(tb, tc)
          end
        end)

        :ok
      end,
      max_concurrency: rest,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    :erlang.garbage_collect()
  end

  defp p11_gc_disposable_trees(%{tasks: tasks, ops: ops}) do
    anchor =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..60, fn i ->
          {String.pad_leading("gca#{i}", 32), CMerkleTree.hash("gca#{i}")}
        end)
      )

    other =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..60, fn i ->
          {String.pad_leading("gco#{i}", 32), CMerkleTree.hash("gco#{i}")}
        end)
      )

    1..tasks
    |> Task.async_stream(
      fn w ->
        Enum.each(1..ops, fn j ->
          disposable =
            CMerkleTree.new()
            |> CMerkleTree.insert_items(
              Enum.map(1..15, fn k ->
                {String.pad_leading("t#{w}_#{j}_#{k}", 32), CMerkleTree.hash("t#{w}#{j}#{k}")}
              end)
            )

          _ = CMerkleTree.root_hash(disposable)
          _ = CMerkleTree.difference(anchor, other)

          if rem(j, 5) == 0 do
            _ =
              anchor
              |> CMerkleTree.clone()
              |> CMerkleTree.lock()
          end
        end)

        if rem(w, 4) == 0, do: :erlang.garbage_collect()
        :ok
      end,
      max_concurrency: tasks,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp p12_uncompact_and_diff(%{tasks: tasks, accounts: n}) do
    compact = build_compact_accounts(n)
    workers = div(tasks, 2) |> max(1)
    uncompact_workers = tasks - workers

    uncompact_f = fn ->
      Task.async_stream(
        1..uncompact_workers,
        fn _ ->
          {accounts, _store, _hash} = CAccountMap.uncompact_state(compact)
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
            CMerkleTree.insert_items(CMerkleTree.new(), [
              {slot(i), <<i::unsigned-size(256)>>},
              {slot(i + 5000), <<i + 1::unsigned-size(256)>>}
            ])

          b =
            CMerkleTree.insert_items(CMerkleTree.new(), [
              {slot(i), <<i + 9::unsigned-size(256)>>},
              {slot(i + 9000), <<i + 2::unsigned-size(256)>>}
            ])

          CMerkleTree.difference(a, b)
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
    {base, _store, _hash} = CAccountMap.uncompact_state(compact)

    1..tasks
    |> Task.async_stream(
      fn w ->
        Enum.each(1..ops, fn j ->
          case rem(w + j, 5) do
            0 ->
              fork = CAccountMap.clone(base)

              new_storage =
                CMerkleTree.insert(CMerkleTree.new(), slot(w + j), <<j::unsigned-size(256)>>)

              _ = CAccountMap.put(fork, addr(rem(w, n) + 1), j, j * 100, new_storage, <<j>>)

            1 ->
              id = addr(rem(w, n) + 1)
              {_, _, storage, _} = CAccountMap.get(base, id)

              alt =
                CMerkleTree.insert(
                  CMerkleTree.clone(storage),
                  slot(w + j + 50_000),
                  <<j::unsigned-size(256)>>
                )

              _ = CMerkleTree.difference(storage, alt)

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
          acc0 = State.account(acc, id)
          tree = Account.tree(acc0)

          tree =
            CMerkleTree.insert(tree, slot(i + 100_000), <<i * 11::unsigned-size(256)>>)

          State.set_account(acc, id, Account.put_tree(acc0, tree))
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
      acc0 = State.account(fork, id)
      tree = Account.tree(acc0)

      tree =
        CMerkleTree.insert(tree, slot(w + 300_000), <<w * 13::unsigned-size(256)>>)

      _ = State.set_account(fork, id, Account.put_tree(acc0, tree))
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
          storage_root: CMerkleTree.new(),
          code: <<>>
        })
      end)

    keys =
      Enum.map(1..60, fn i -> String.pad_leading("ds#{i}", 32) end)

    proof_tree =
      Enum.reduce(keys, CMerkleTree.new(), fn k, acc ->
        CMerkleTree.insert(acc, k, CMerkleTree.hash(k))
      end)

    1..tasks
    |> Task.async_stream(
      fn w ->
        case rem(w, 6) do
          0 ->
            _ =
              proof_tree
              |> CMerkleTree.clone()
              |> CMerkleTree.lock()

          1 ->
            _ =
              CMerkleTree.difference(
                Account.tree(State.account(live, addr(1))),
                Account.tree(State.account(other, addr(1)))
              )

          2 ->
            _ = CAccountMap.uncompact_state(compact)

          3 ->
            k = Enum.at(keys, rem(w, length(keys)))
            _ = CMerkleTree.get_proofs(proof_tree, k)
            _ = CMerkleTree.to_list(proof_tree)

          4 ->
            _ =
              proof_tree
              |> CMerkleTree.clone()
              |> CMerkleTree.insert(String.pad_leading("x#{w}", 32), CMerkleTree.hash("x#{w}"))

          _ ->
            _ = CAccountMap.lock(live.accounts, Map.get(live, :store))
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
          acc0 = State.account(acc, id)
          tree = Account.tree(acc0)

          tree =
            CMerkleTree.insert(tree, slot(i + 300_000), <<i * 17::unsigned-size(256)>>)

          State.set_account(acc, id, Account.put_tree(acc0, tree))
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
end

CMerkleParallelStress.main(System.argv())
