# CMerkleTree NIF — targeted stress for heap / invalid-free hypotheses (live crash triage).
#
# Hypothesis map (see c_src/preallocator.hpp, merkletree.cpp, nif.cpp):
#   A — PreAllocator destroy_item/backbuffer vs ~PreAllocator slot count (pair_t ~ on valid storage)
#   B — GlobalStripePool: stripe malloc reused across Tree lifetimes; destructor + pool put
#   C — Second stripe: only first slot used after full first stripe (partial stripe destructor)
#   D — ItemPool COW: clone + write → fork_for_write / clone_for_fork + pair_list clone
#   E — split_node / large trie (leaf_bucket churn, push_back_no_delete paths)
#   F — NIF locked_states enter_lock/leave_lock + root_hash dedup (live server pattern)
#   G — difference/into tree — insert_item on forked structures
#   H — get_proofs + root_hashes — read paths after dirty/update_merkle_hash_count
#
# Run from repo root:
#   mix run --no-start scripts/cmerkle_heap_assumptions.exs -- --rounds 200
#
# Options:
#   --rounds N     repetitions per scenario (default: 150)
#   --suite-pass N run the full scenario list this many times (default: 1)
#   --seed N       RNG seed (default: env MERKLE_HEAP_SEED or fixed 20260415)
#
# Exit 0 only if every scenario completes without raising. Native crashes (abort/segfault)
# are not catchable in Elixir; use ASan build or MERKLE_FUZZ_ASAN with cmerkle_fuzz.sh pattern.

defmodule CMerkleHeapAssumptions do
  @moduledoc false

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
          rounds: :integer,
          suite_pass: :integer,
          seed: :integer
        ]
      )

    rounds = Keyword.get(opts, :rounds, env_int("MERKLE_HEAP_ROUNDS") || 150)
    suite_pass = Keyword.get(opts, :suite_pass, env_int("MERKLE_HEAP_SUITE_PASS") || 1)

    seed =
      Keyword.get(opts, :seed) ||
        env_int("MERKLE_HEAP_SEED") ||
        20_260_415

    :rand.seed(:exsss, {seed, seed, seed})

    {_ib, _pb, _plb, _tb, stripe} = CMerkleTree.struct_sizes()

    IO.puts(:stderr, """
    === CMerkleTree heap assumption stress ===
    otp=#{System.otp_release()} elixir=#{System.version()} pid=#{:os.getpid()}
    seed=#{seed} rounds_per_scenario=#{rounds} suite_passes=#{suite_pass} stripe_size=#{stripe}
    """)

    ctx = %{rounds: rounds, stripe: stripe, seed: seed}

    Enum.each(1..suite_pass, fn pass ->
      IO.puts(:stderr, "--- suite pass #{pass}/#{suite_pass} ---")

      for {id, title, fun} <- scenarios() do
        t0 = System.monotonic_time(:millisecond)

        try do
          fun.(ctx)
          dt = System.monotonic_time(:millisecond) - t0
          IO.puts(:stderr, "ASSUMPTION_OK #{id} #{inspect(title)} #{dt}ms")
        catch
          kind, reason ->
            IO.puts(:stderr, "ASSUMPTION_FAIL #{id} #{inspect(title)} kind=#{inspect(kind)} reason=#{inspect(reason)}")
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
      end
    end)

    IO.puts(:stderr, "=== all scenarios finished (Elixir layer); exit 0 ===")
  end

  defp env_int(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      s -> String.to_integer(String.trim(s))
    end
  rescue
    ArgumentError -> nil
  end

  defp scenarios do
    [
      {:A, "destroy_item/backbuffer: heavy delete+reinsert on one tree", &a_delete_reinsert_churn/1},
      {:B, "GlobalStripePool: many short-lived trees (alloc+drop)", &b_short_lived_trees/1},
      {:C, "stripe boundary: exactly stripe+1 keys then shrink", &c_second_stripe_partial/1},
      {:D, "COW fork: clone then write (make_writeable path)", &d_clone_write_fork/1},
      {:E, "large trie: many inserts (split_node / internal nodes)", &e_large_many_keys/1},
      {:F, "lock + clone chain (NIF locked_states / root_hash dedup)", &f_lock_clone_chain/1},
      {:G, "difference on large divergent trees", &g_difference_heavy/1},
      {:H, "proofs + root_hashes after deep updates", &h_proofs_and_hashes/1}
    ]
  end

  # A: pair_t destroy_item -> backbuffer; PreAllocator ~ must match constructed slots.
  defp a_delete_reinsert_churn(%{rounds: r}) do
    n = max(120, min(r, 400))
    keys = Enum.map(1..n, fn i -> String.pad_leading("#{i}", 32) end)

    t =
      Enum.reduce(keys, CMerkleTree.new(), fn k, acc ->
        CMerkleTree.insert(acc, k, CMerkleTree.hash("a#{k}"))
      end)

    Enum.each(1..r, fn round ->
      to_del = Enum.take_random(keys, min(40 + rem(round, 30), div(n, 2)))

      t =
        Enum.reduce(to_del, t, fn k, acc ->
          CMerkleTree.delete(acc, k)
        end)

      t =
        Enum.reduce(to_del, t, fn k, acc ->
          CMerkleTree.insert(acc, k, CMerkleTree.hash("b#{k}#{round}"))
        end)

      _ = CMerkleTree.root_hash(t)
      _ = CMerkleTree.size(t)
      :ok
    end)
  end

  # B: tree destroyed -> SharedState ~Tree -> PreAllocator ~ ; stripes may return to global pool.
  defp b_short_lived_trees(%{rounds: r}) do
    Enum.each(1..max(r, 200), fn i ->
      k = rem(i, 50) + 5

      data =
        Enum.map(1..k, fn j ->
          {String.pad_leading("#{i}_#{j}", 32), CMerkleTree.hash("s#{i}_#{j}")}
        end)

      t = CMerkleTree.new() |> CMerkleTree.insert_items(data)
      _ = CMerkleTree.root_hash(t)
      _ = CMerkleTree.bucket_count(t)
      :ok
    end)
  end

  # C: first stripe full (8) then minimal use of second stripe — destructor len on stripe 2.
  defp c_second_stripe_partial(%{rounds: r, stripe: s}) do
    Enum.each(1..max(div(r, 2), 40), fn pass ->
      # Fill exactly s keys (one full stripe of pair allocations), then add one on next stripe.
      base = Enum.map(1..s, fn i -> {String.pad_leading("c#{pass}_#{i}", 32), CMerkleTree.hash("c#{i}")} end)
      extra = {String.pad_leading("c#{pass}_extra", 32), CMerkleTree.hash("extra")}

      t = CMerkleTree.new() |> CMerkleTree.insert_items(base)
      t = CMerkleTree.insert(t, elem(extra, 0), elem(extra, 1))
      _ = CMerkleTree.root_hash(t)

      # Shrink back toward boundary (deletes use insert null — churns PreAllocator).
      t =
        Enum.reduce(1..div(s, 2), t, fn i, acc ->
          CMerkleTree.delete(acc, String.pad_leading("c#{pass}_#{i}", 32))
        end)

      _ = CMerkleTree.root_hash(t)
      _ = CMerkleTree.size(t)
      :ok
    end)
  end

  # D: shared Tree copy + pool; write triggers clone_for_write / fork.
  defp d_clone_write_fork(%{rounds: r}) do
    n = max(80, min(r, 350))

    base =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..n, fn i -> {String.pad_leading("d#{i}", 32), CMerkleTree.hash("d#{i}")} end)
      )

    Enum.each(1..max(div(r, 3), 30), fn i ->
      a = CMerkleTree.clone(base) |> CMerkleTree.insert(String.pad_leading("dx#{i}", 32), CMerkleTree.hash("dx#{i}"))
      b = CMerkleTree.clone(base) |> CMerkleTree.insert(String.pad_leading("dy#{i}", 32), CMerkleTree.hash("dy#{i}"))
      _ = CMerkleTree.root_hash(a)
      _ = CMerkleTree.root_hash(b)
      _ = CMerkleTree.difference(a, b)
      :ok
    end)
  end

  # E: many keys — stress split_node, internal merge paths in update_merkle_hash_count.
  defp e_large_many_keys(%{rounds: r}) do
    n = max(800, min(r * 8, 6000))

    data =
      Enum.map(1..n, fn i ->
        {String.pad_leading("e#{i}", 32), CMerkleTree.hash("e#{i}")}
      end)

    t = CMerkleTree.new() |> CMerkleTree.insert_items(data)
    _ = CMerkleTree.root_hash(t)
    _ = CMerkleTree.root_hashes(t)
    _ = CMerkleTree.bucket_count(t)
    :ok
  end

  # F: lock registers root in NIF map; clone hits enter_lock path — live server pattern.
  defp f_lock_clone_chain(%{rounds: r}) do
    data = Enum.map(1..120, fn i -> {String.pad_leading("f#{i}", 32), CMerkleTree.hash("f#{i}")} end)
    base = CMerkleTree.new() |> CMerkleTree.insert_items(data) |> CMerkleTree.lock()

    Enum.each(1..max(div(r, 5), 25), fn i ->
      t =
        CMerkleTree.clone(base)
        |> CMerkleTree.insert(String.pad_leading("fz#{i}", 32), CMerkleTree.hash("fz#{i}"))
        |> CMerkleTree.lock()

      _ = CMerkleTree.root_hash(t)
      :ok
    end)
  end

  # G: difference walks both trees — clone_for_fork on into.insert_item.
  defp g_difference_heavy(%{rounds: r}) do
    m = max(200, min(r * 3, 900))

    a =
      Enum.map(1..m, fn i -> {String.pad_leading("g#{i}", 32), CMerkleTree.hash("ga#{i}")} end)

    b =
      Enum.map(1..m, fn i -> {String.pad_leading("g#{i}", 32), CMerkleTree.hash("gb#{i}")} end)

    ta = CMerkleTree.new() |> CMerkleTree.insert_items(a)
    tb = CMerkleTree.new() |> CMerkleTree.insert_items(b)
    diff = CMerkleTree.difference(ta, tb)
    _ = map_size(diff)
    _ = CMerkleTree.root_hash(ta)
    _ = CMerkleTree.root_hash(tb)
    :ok
  end

  # H: get_proofs + root_hashes after updates — read paths over possibly merged buckets.
  defp h_proofs_and_hashes(%{rounds: r}) do
    n = max(100, min(r * 2, 600))
    keys = Enum.map(1..n, fn i -> String.pad_leading("h#{i}", 32) end)

    t =
      Enum.reduce(keys, CMerkleTree.new(), fn k, acc ->
        CMerkleTree.insert(acc, k, CMerkleTree.hash(k))
      end)

    Enum.each(1..min(80, max(div(r, 2), 20)), fn _ ->
      k = Enum.random(keys)
      _ = CMerkleTree.get_proofs(t, k)
      _ = CMerkleTree.root_hashes(t)
      :ok
    end)
  end
end

CMerkleHeapAssumptions.main(System.argv())
