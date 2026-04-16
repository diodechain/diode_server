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
#
# Exit 0 if all waves complete. Native crashes are not caught in Elixir.

defmodule CMerkleParallelStress do
  @moduledoc false

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
          seed: :integer
        ]
      )

    tasks = Keyword.get(opts, :tasks, 32)
    waves = Keyword.get(opts, :waves, 2)
    ops = Keyword.get(opts, :ops, 40)

    seed =
      Keyword.get(opts, :seed) ||
        (case System.get_env("MERKLE_PARALLEL_SEED") do
           nil -> 20_260_416
           "" -> 20_260_416
           s -> String.to_integer(String.trim(s))
         end)

    :rand.seed(:exsss, {seed, seed, seed})

    IO.puts(:stderr, """
    === CMerkleTree parallel stress ===
    otp=#{System.otp_release()} elixir=#{System.version()} schedulers=#{System.schedulers_online()}
    seed=#{seed} tasks=#{tasks} waves=#{waves} ops_per_task=#{ops}
    """)

    ctx = %{tasks: tasks, ops: ops, seed: seed}

    Enum.each(1..waves, fn w ->
      IO.puts(:stderr, "--- wave #{w}/#{waves} ---")

      run_named("P1_same_tree_rw", fn -> p1_same_tree_rw(ctx) end)
      run_named("P2_concurrent_difference_ab", fn -> p2_concurrent_difference(ctx, :ab) end)
      run_named("P3_concurrent_difference_ba", fn -> p2_concurrent_difference(ctx, :ba) end)
      run_named("P4_clone_write_storm", fn -> p4_clone_storm(ctx) end)
      run_named("P5_interleave_mutate_and_diff", fn -> p5_interleave(ctx) end)
      run_named("P6_concurrent_lock", fn -> p6_concurrent_lock(ctx) end)
      run_named("P7_many_shortlived_trees", fn -> p7_shortlived_parallel(ctx) end)
      run_named("P8_proofs_and_to_list", fn -> p8_proofs_to_list(ctx) end)
    end)

    IO.puts(:stderr, "=== parallel stress finished (Elixir layer); exit 0 ===")
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
          CMerkleTree.insert(acc, String.pad_leading("c#{w}_#{j}", 32), CMerkleTree.hash("x#{w}#{j}"))
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
        Enum.map(1..100, fn i -> {String.pad_leading("ia#{i}", 32), CMerkleTree.hash("ia#{i}")} end)
      )

    tb =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..100, fn i -> {String.pad_leading("ib#{i}", 32), CMerkleTree.hash("ib#{i}")} end)
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
    data = Enum.map(1..60, fn i -> {String.pad_leading("L#{i}", 32), CMerkleTree.hash("L#{i}")} end)
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
end

CMerkleParallelStress.main(System.argv())
