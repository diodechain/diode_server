# CMerkleTree NIF stress / fuzz harness.
# Run from repo root (use --no-start to avoid booting the full Diode app):
#   mix run --no-start scripts/cmerkle_fuzz.exs -- --iterations 10000 --seed 42
# Environment (optional): MERKLE_FUZZ_ITERATIONS, MERKLE_FUZZ_SEED, MERKLE_FUZZ_MAX_KEYS
#
# Options:
#   --iterations N   number of fuzz rounds (default: 0 = run until SIGINT)
#   --seed N         RNG seed for reproducibility (default: random)
#   --max-keys N     cap keys per tree per scenario (default: 900)
#
# Each successful round prints: FUZZ_OK <round> <scenario>
# On Elixir exception, prints stack trace then exits non-zero.
# Native crashes (segfault/abort) are not caught here; use scripts/cmerkle_fuzz.sh for a log file.

defmodule CMerkleFuzz do
  @moduledoc false

  alias Chain.{Account, State}

  # mix run script.exs -- --iterations N passes ["--", "--iterations", "N"]; strip the leading "--".
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
          iterations: :integer,
          seed: :integer,
          max_keys: :integer,
          max_rss_delta_kb: :integer,
          scenario: :integer
        ]
      )

    iterations =
      case Keyword.fetch(opts, :iterations) do
        {:ok, n} -> n
        :error -> env_int("MERKLE_FUZZ_ITERATIONS") || 0
      end

    max_keys =
      case Keyword.fetch(opts, :max_keys) do
        {:ok, n} -> max(n, 16)
        :error -> max(env_int("MERKLE_FUZZ_MAX_KEYS") || 900, 16)
      end

    seed =
      case Keyword.fetch(opts, :seed) do
        {:ok, s} ->
          s

        :error ->
          case env_int("MERKLE_FUZZ_SEED") do
            nil -> :rand.uniform(1_000_000_000)
            s -> s
          end
      end

    :rand.seed(:exsss, {seed, seed, seed})

    IO.puts(:stderr, """
    === CMerkleTree fuzz ===
    #{runtime_banner()}
    seed=#{seed} iterations=#{iterations |> format_iters()} max_keys=#{max_keys}
    """)

    ctx = %{max_keys: max_keys, seed: seed, scenario: Keyword.get(opts, :scenario)}

    case Keyword.fetch(opts, :max_rss_delta_kb) do
      {:ok, kb} when kb > 0 ->
        Process.put(:cmerkle_fuzz_baseline_rss, read_proc_rss_kb())
        Process.put(:cmerkle_fuzz_max_rss_delta, kb)

      _ ->
        :ok
    end

    if iterations <= 0 do
      Stream.iterate(1, &(&1 + 1))
      |> Enum.each(fn round ->
        run_round(round, ctx)
      end)
    else
      Enum.each(1..iterations, fn round ->
        run_round(round, ctx)
      end)
    end

    IO.puts(:stderr, "=== fuzz finished cleanly ===")
  end

  defp format_iters(0), do: "infinite (SIGINT to stop)"
  defp format_iters(n), do: Integer.to_string(n)

  defp runtime_banner do
    "otp=#{System.otp_release()} elixir=#{System.version()} pid=#{:os.getpid()}"
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

  defp run_round(round, ctx) do
    scenario = ctx[:scenario] || :rand.uniform(31)

    case scenario do
      1 -> s_string_batch_insert_diff(round, ctx)
      2 -> s_u256_sequential_diff(round, ctx)
      3 -> s_clone_parallel_extensions_diff(round, ctx)
      4 -> s_clone_overwrite_diff(round, ctx)
      5 -> s_triple_fork_diff(round, ctx)
      6 -> s_delete_and_reinsert(round, ctx)
      7 -> s_proofs_and_roots(round, ctx)
      8 -> s_lock_clone_insert(round, ctx)
      9 -> s_lock_and_difference(round, ctx)
      10 -> s_account_map_uncompact(round, ctx)
      11 -> s_account_map_clone_mutate(round, ctx)
      12 -> s_uncompact_and_storage_diff(round, ctx)
      13 -> s_account_get_materialize_diff(round, ctx)
      14 -> s_gc_during_lock_diff(round, ctx)
      15 -> s_import_map_lock_diff(round, ctx)
      16 -> s_state_lock_clone_mutate(round, ctx)
      17 -> s_account_map_lock_bulk(round, ctx)
      18 -> s_account_map_lock_concurrent(round, ctx)
      19 -> s_account_map_list_diff_large_compact(round, ctx)
      20 -> s_list_diff_vs_to_list(round, ctx)
      21 -> s_list_diff_vs_account_map_lock(round, ctx)
      22 -> s_list_diff_vs_clone_put(round, ctx)
      23 -> s_list_diff_vs_storage_difference(round, ctx)
      24 -> s_dual_map_list_diff_order(round, ctx)
      25 -> s_list_diff_compact_vs_live(round, ctx)
      26 -> s_list_diff_vs_uncompact(round, ctx)
      27 -> s_list_diff_vs_state_lock(round, ctx)
      28 -> s_list_diff_vs_account_map_get(round, ctx)
      29 -> s_list_diff_gc_pressure(round, ctx)
      30 -> s_prepare_state_composite(round, ctx)
      31 -> s_clone_equivalence(round, ctx)
      other -> raise("unknown fuzz scenario #{inspect(other)}")
    end

    if rem(round, 50) == 0 do
      :erlang.garbage_collect()

      if max_rss_delta = Process.get(:cmerkle_fuzz_max_rss_delta) do
        check_fuzz_rss(max_rss_delta, round)
      end
    end

    IO.puts("FUZZ_OK #{round} #{scenario}")
  end

  defp s_string_batch_insert_diff(_round, %{max_keys: mk}) do
    n = :rand.uniform(div(mk, 2)) + 40
    data = Enum.map(1..n, fn i -> {String.pad_leading("#{i}", 32), CMerkleTree.hash("f#{i}")} end)
    {a, rest} = Enum.split(data, div(n * 3, 5))
    {b, c} = Enum.split(rest, div(length(rest), 2) |> max(1))

    base = CMerkleTree.new() |> CMerkleTree.insert_items(a)

    t2 =
      base |> CMerkleTree.clone() |> CMerkleTree.insert_items(b ++ c)

    t_alt =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(b)
      |> CMerkleTree.insert_items(Enum.take(c, min(length(c), 50)))

    _ = CMerkleTree.difference(t2, t_alt)
    _ = CMerkleTree.root_hash(t2)
    _ = CMerkleTree.root_hash(t_alt)
  end

  defp s_u256_sequential_diff(_round, %{max_keys: mk}) do
    hi = :rand.uniform(min(mk, 520)) + 80

    slots =
      Enum.map(0..hi, fn i ->
        {<<i::unsigned-size(256)>>, <<i * 7 + 1::unsigned-size(256)>>}
      end)

    base = CMerkleTree.new() |> CMerkleTree.insert_items(slots)

    left =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(
        Enum.map((hi + 1)..(hi + 40), fn i ->
          {<<i::unsigned-size(256)>>, <<i * 3::unsigned-size(256)>>}
        end)
      )

    right =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(
        Enum.map((hi + 41)..(hi + 95), fn i ->
          {<<i::unsigned-size(256)>>, <<i * 13::unsigned-size(256)>>}
        end)
      )

    _ = CMerkleTree.difference(left, right)
    _ = CMerkleTree.root_hash(left)
    _ = CMerkleTree.root_hash(right)
  end

  defp s_clone_parallel_extensions_diff(_round, %{max_keys: mk}) do
    hi = :rand.uniform(min(mk, 400)) + 50

    base =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(0..hi, fn i -> {<<i::unsigned-size(256)>>, <<i * 11::unsigned-size(256)>>} end)
      )

    ext1 = (hi + 1)..(hi + 30)
    ext2 = (hi + 31)..(hi + 70)

    left =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(
        Enum.map(ext1, fn i -> {<<i::unsigned-size(256)>>, <<i::unsigned-size(256)>>} end)
      )

    right =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(
        Enum.map(ext2, fn i -> {<<i::unsigned-size(256)>>, <<i + 9::unsigned-size(256)>>} end)
      )

    _ = CMerkleTree.difference(left, right)
  end

  defp s_clone_overwrite_diff(_round, %{max_keys: mk}) do
    hi = :rand.uniform(min(mk, 350)) + 80

    base =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(0..hi, fn i -> {<<i::unsigned-size(256)>>, <<i * 5::unsigned-size(256)>>} end)
      )

    left =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(
        Enum.map((hi + 1)..(hi + 35), fn i ->
          {<<i::unsigned-size(256)>>, <<i * 2::unsigned-size(256)>>}
        end)
      )

    lo = div(hi, 4)
    mid = lo + :rand.uniform(max(div(hi - lo, 2), 5))

    right =
      base
      |> CMerkleTree.clone()
      |> then(fn t ->
        Enum.reduce(lo..mid, t, fn i, acc ->
          CMerkleTree.insert(acc, <<i::unsigned-size(256)>>, <<i * 17::unsigned-size(256)>>)
        end)
      end)

    _ = CMerkleTree.difference(left, right)
  end

  defp s_triple_fork_diff(_round, %{max_keys: mk}) do
    n = :rand.uniform(min(mk, 280)) + 60

    base =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..n, fn i -> {String.pad_leading("#{i}", 32), CMerkleTree.hash("b#{i}")} end)
      )

    a =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert(String.pad_leading("x", 32), CMerkleTree.hash("x"))

    b =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert(String.pad_leading("y", 32), CMerkleTree.hash("y"))

    c =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert(String.pad_leading("z", 32), CMerkleTree.hash("z"))

    _ = CMerkleTree.difference(a, b)
    _ = CMerkleTree.difference(b, c)
    _ = CMerkleTree.difference(a, c)
  end

  defp s_delete_and_reinsert(_round, %{max_keys: mk}) do
    n = :rand.uniform(min(mk, 200)) + 30
    keys = Enum.map(1..n, fn i -> String.pad_leading("#{i}", 32) end)

    t =
      Enum.reduce(keys, CMerkleTree.new(), fn k, acc ->
        CMerkleTree.insert(acc, k, CMerkleTree.hash(k))
      end)

    to_del = Enum.take_random(keys, div(length(keys), 3) |> max(3))

    t =
      Enum.reduce(to_del, t, fn k, acc ->
        CMerkleTree.delete(acc, k)
      end)

    t =
      Enum.reduce(to_del, t, fn k, acc ->
        CMerkleTree.insert(acc, k, CMerkleTree.hash("re#{k}"))
      end)

    _ = CMerkleTree.root_hash(t)
    _ = CMerkleTree.size(t)
  end

  defp s_proofs_and_roots(_round, %{max_keys: mk}) do
    hi = :rand.uniform(min(180, mk)) + 20

    t =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(0..hi, fn i -> {<<i::unsigned-size(256)>>, <<i * 3::unsigned-size(256)>>} end)
      )

    _ = CMerkleTree.root_hash(t)
    _ = CMerkleTree.root_hashes(t)
    k = <<:rand.uniform(hi)::unsigned-size(256)>>
    _ = CMerkleTree.get_proofs(t, k)
  end

  # --- S8–S18: lock, account map, GC, bulk account_map_lock (see c_src/LOCK_ORDER.md) ---

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp slot(i), do: <<i::unsigned-size(256)>>

  defp build_compact_accounts(n) do
    for i <- 1..n, into: %{} do
      tree =
        CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i * 3::unsigned-size(256)>>)

      acc = %Account{nonce: i, balance: i * 1_000, storage_root: tree, code: <<i>>}
      {addr(i), Account.compact(acc)}
    end
  end

  defp s_lock_clone_insert(_round, %{max_keys: mk}) do
    n = :rand.uniform(min(mk, 120)) + 20

    base =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..n, fn i -> {String.pad_leading("lk#{i}", 32), CMerkleTree.hash("lk#{i}")} end)
      )

    locked =
      if :rand.uniform(2) == 1 do
        base
        |> CMerkleTree.clone()
        |> CMerkleTree.insert(String.pad_leading("pre_lock", 32), CMerkleTree.hash("pre"))
        |> CMerkleTree.lock()
      else
        base
        |> CMerkleTree.clone()
        |> CMerkleTree.lock()
      end

    _ = CMerkleTree.root_hash(locked)
  end

  defp s_lock_and_difference(_round, %{max_keys: mk}) do
    n = :rand.uniform(min(mk, 100)) + 30

    shared =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..n, fn i -> {String.pad_leading("sh#{i}", 32), CMerkleTree.hash("sh#{i}")} end)
      )

    other =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..n, fn i -> {String.pad_leading("ot#{i}", 32), CMerkleTree.hash("ot#{i}")} end)
      )

    _ =
      shared
      |> CMerkleTree.clone()
      |> CMerkleTree.lock()

    _ = CMerkleTree.difference(shared, other)
    _ = CMerkleTree.difference(other, shared)
  end

  defp s_account_map_uncompact(_round, _ctx) do
    n = :rand.uniform(180) + 20
    compact = build_compact_accounts(n)
    {accounts, _hash} = CAccountMap.uncompact_state(compact)
    if CAccountMap.size(accounts) != n, do: raise("uncompact size mismatch")
  end

  defp s_account_map_clone_mutate(_round, _ctx) do
    n = :rand.uniform(80) + 10
    compact = build_compact_accounts(n)
    {accounts, _hash} = CAccountMap.uncompact_state(compact)

    fork =
      accounts
      |> CAccountMap.clone()
      |> CAccountMap.put(addr(1), 99, 99_000, CMerkleTree.new(), <<99>>)

    _ = CAccountMap.to_list(accounts)

    if CAccountMap.size(fork) != n, do: raise("fork size mismatch")
  end

  defp s_uncompact_and_storage_diff(_round, _ctx) do
    n = :rand.uniform(60) + 20
    compact = build_compact_accounts(n)

    parent = Task.async(fn -> CAccountMap.uncompact_state(compact) end)

    diffs =
      1..4
      |> Task.async_stream(
        fn i ->
          a =
            CMerkleTree.insert_items(CMerkleTree.new(), [
              {slot(i), <<i::unsigned-size(256)>>},
              {slot(i + 1000), <<i + 1::unsigned-size(256)>>}
            ])

          b =
            CMerkleTree.insert_items(CMerkleTree.new(), [
              {slot(i), <<i + 7::unsigned-size(256)>>},
              {slot(i + 2000), <<i + 2::unsigned-size(256)>>}
            ])

          CMerkleTree.difference(a, b)
        end,
        max_concurrency: 4,
        timeout: 60_000,
        ordered: false
      )
      |> Enum.to_list()

    {accounts, _hash} = Task.await(parent, 120_000)
    if length(diffs) != 4, do: raise("diff task count mismatch")
    if CAccountMap.size(accounts) != n, do: raise("uncompact size mismatch")
  end

  defp s_account_get_materialize_diff(_round, _ctx) do
    n = :rand.uniform(40) + 5
    compact = build_compact_accounts(n)
    {accounts, _hash} = CAccountMap.uncompact_state(compact)

    {_n, _b, root, _c} = CAccountMap.get(accounts, addr(1))
    if not is_binary(root) or byte_size(root) != 32, do: raise("expected 32-byte root hash")

    # Exercise storage APIs (get no longer returns a live trie for difference).
    _ = CAccountMap.storage_get(accounts, addr(1), slot(1))
    _ = CAccountMap.storage_root_hash(accounts, addr(1))
    _ = CAccountMap.storage_to_list(accounts, addr(1))
    _ = CAccountMap.get(accounts, addr(2))
  end

  defp s_gc_during_lock_diff(_round, %{max_keys: mk}) do
    n = :rand.uniform(min(mk, 80)) + 20

    shared =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..n, fn i -> {String.pad_leading("gc#{i}", 32), CMerkleTree.hash("gc#{i}")} end)
      )

    other =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..n, fn i -> {String.pad_leading("go#{i}", 32), CMerkleTree.hash("go#{i}")} end)
      )

    1..6
    |> Task.async_stream(
      fn w ->
        if rem(w, 2) == 0 do
          _ =
            shared
            |> CMerkleTree.clone()
            |> CMerkleTree.lock()
        else
          _ = CMerkleTree.difference(shared, other)
        end

        :ok
      end,
      max_concurrency: 6,
      timeout: 60_000,
      ordered: false
    )
    |> Stream.run()

    short =
      Enum.map(1..12, fn i ->
        {String.pad_leading("tmp#{i}", 32), CMerkleTree.hash("tmp#{i}")}
      end)

    _ = CMerkleTree.new() |> CMerkleTree.insert_items(short)
    :erlang.garbage_collect()
  end

  defp s_import_map_lock_diff(_round, %{max_keys: mk}) do
    n = :rand.uniform(min(mk, 150)) + 30

    items =
      for i <- 1..n, into: %{} do
        {String.pad_leading("im#{i}", 32), CMerkleTree.hash("im#{i}")}
      end

    tree = CMerkleTree.new() |> CMerkleTree.import_map(items)

    sibling =
      tree
      |> CMerkleTree.clone()
      |> CMerkleTree.insert(String.pad_leading("extra", 32), CMerkleTree.hash("extra"))

    _ =
      tree
      |> CMerkleTree.clone()
      |> CMerkleTree.lock()

    _ = CMerkleTree.difference(tree, sibling)
    _ = CMerkleTree.root_hash(tree)
  end

  defp s_state_lock_clone_mutate(_round, _ctx) do
    n = :rand.uniform(60) + 10
    compact = build_compact_accounts(n)

    parent =
      compact
      |> then(fn accounts -> %State{accounts: accounts} end)
      |> State.uncompact()

    if :rand.uniform(2) == 1 do
      parent = State.normalize(parent)
    end

    _ = State.hash(parent)
    Chain.State.lock(parent)
    fork = State.clone(parent)

    writes = :rand.uniform(min(n, 12)) + 1

    fork =
      Enum.reduce(1..writes, fork, fn j, state ->
        id = addr(rem(j, n) + 1)

        State.storage_put_map(state, %{
          id => %{slot(j + 50_000) => <<j * 17::unsigned-size(256)>>}
        })
      end)

    fork_hash = State.hash(fork)
    unless is_binary(fork_hash), do: raise("fork hash not binary")

    for j <- 1..writes do
      id = addr(rem(j, n) + 1)

      if State.storage_value(parent, id, slot(j + 50_000)) !=
           <<0::unsigned-size(256)>> do
        raise("parent mutated after lock->clone fork write")
      end
    end
  end

  defp s_account_map_lock_bulk(_round, _ctx) do
    n = :rand.uniform(100) + 20
    group = :rand.uniform(8) + 2

    map =
      Enum.reduce(1..n, CAccountMap.new(), fn i, acc ->
        g = div(i - 1, group)

        storage =
          CMerkleTree.insert_items(CMerkleTree.new(), [
            {slot(g + 1), <<g + 1::unsigned-size(256)>>}
          ])

        CAccountMap.put(acc, addr(i), i, i * 1_000, storage, <<i>>)
      end)

    store =
      CMerkleTree.insert_items(CMerkleTree.new(), [
        {slot(88_888), <<88_888::unsigned-size(256)>>}
      ])

    _ = CAccountMap.lock(map)

    fork =
      map
      |> CAccountMap.clone()
      |> CAccountMap.put(addr(1), 77, 77_000, CMerkleTree.new(), <<77>>)

    if CAccountMap.size(fork) != n, do: raise("fork size mismatch")

    if CAccountMap.get(map, addr(1)) == CAccountMap.get(fork, addr(1)),
      do: raise("parent mutated")
  end

  defp s_account_map_lock_concurrent(_round, _ctx) do
    n = :rand.uniform(60) + 20

    map =
      Enum.reduce(1..n, CAccountMap.new(), fn i, acc ->
        storage =
          CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i * 5::unsigned-size(256)>>)

        CAccountMap.put(acc, addr(i), i, i * 1_000, storage, <<i>>)
      end)

    workers = 6

    1..workers
    |> Task.async_stream(
      fn w ->
        if rem(w, 2) == 0 do
          _ = CAccountMap.lock(map)
        else
          _ = CAccountMap.storage_root_hash(map, addr(1))
          _ = CAccountMap.storage_root_hash(map, addr(min(n, 2)))
          _ = CAccountMap.storage_to_list(map, addr(1))
        end

        :ok
      end,
      max_concurrency: workers,
      timeout: 60_000,
      ordered: false
    )
    |> Stream.run()
  end

  # --- S19–S30: native account_map difference_full (see c_src/LOCK_ORDER.md D-C7, D-D7) ---

  defp s_account_map_list_diff_large_compact(_round, _ctx) do
    n = :rand.uniform(200) + 100
    compact = build_compact_accounts(n)
    {base, _hash} = CAccountMap.uncompact_state(compact)

    fork =
      CAccountMap.clone(base)
      |> then(fn map ->
        i = :rand.uniform(n)

        map
        |> CAccountMap.storage_put_map(%{
          addr(i) => %{slot(i + 400_000) => <<i::unsigned-size(256)>>}
        })
        |> then(fn m ->
          {nonce, balance, _root, code} = CAccountMap.get(m, addr(i))
          CAccountMap.put_meta(m, addr(i), nonce + 1, balance, code)
        end)
      end)

    _ = CAccountMap.difference_full(base, fork)
  end

  defp s_list_diff_vs_to_list(_round, _ctx) do
    n = :rand.uniform(80) + 20
    map = build_account_map(n)
    fork = CAccountMap.clone(map)

    workers = 6

    1..workers
    |> Task.async_stream(
      fn w ->
        if rem(w, 2) == 0 do
          _ = CAccountMap.difference_full(map, fork)
        else
          _ = CAccountMap.to_list(map)
        end

        :ok
      end,
      max_concurrency: workers,
      timeout: 60_000,
      ordered: false
    )
    |> Stream.run()
  end

  defp s_list_diff_vs_account_map_lock(_round, _ctx) do
    map = build_account_map(:rand.uniform(60) + 20)
    fork = CAccountMap.clone(map)

    workers = 6

    1..workers
    |> Task.async_stream(
      fn w ->
        if rem(w, 2) == 0 do
          _ = CAccountMap.difference_full(map, fork)
        else
          _ = CAccountMap.lock(map)
        end

        :ok
      end,
      max_concurrency: workers,
      timeout: 60_000,
      ordered: false
    )
    |> Stream.run()
  end

  defp s_list_diff_vs_clone_put(_round, _ctx) do
    map = build_account_map(:rand.uniform(50) + 15)

    workers = 6

    1..workers
    |> Task.async_stream(
      fn w ->
        fork = CAccountMap.clone(map)

        if rem(w, 2) == 0 do
          _ = CAccountMap.difference_full(map, fork)
        else
          i = rem(w, 10) + 1
          storage = CMerkleTree.insert(CMerkleTree.new(), slot(w + i), <<w::unsigned-size(256)>>)
          _ = CAccountMap.put(fork, addr(i), w, w * 100, storage, <<w>>)
        end

        :ok
      end,
      max_concurrency: workers,
      timeout: 60_000,
      ordered: false
    )
    |> Stream.run()
  end

  defp s_list_diff_vs_storage_difference(_round, _ctx) do
    map = build_account_map(:rand.uniform(40) + 10)

    workers = 6

    1..workers
    |> Task.async_stream(
      fn w ->
        if rem(w, 2) == 0 do
          _ = CAccountMap.difference_full(map, CAccountMap.clone(map))
        else
          _ = CAccountMap.storage_root_hash(map, addr(1))
          _ = CAccountMap.storage_root_hash(map, addr(2))
          _ = CAccountMap.storage_to_list(map, addr(1))
        end

        :ok
      end,
      max_concurrency: workers,
      timeout: 60_000,
      ordered: false
    )
    |> Stream.run()
  end

  defp s_dual_map_list_diff_order(_round, _ctx) do
    a = build_account_map(:rand.uniform(50) + 10)
    b = CAccountMap.clone(a)
    i = :rand.uniform(10) + 1

    b =
      b
      |> CAccountMap.storage_put_map(%{
        addr(i) => %{slot(88_888) => <<88_888::unsigned-size(256)>>}
      })
      |> then(fn m ->
        {nonce, balance, _root, code} = CAccountMap.get(m, addr(i))
        CAccountMap.put_meta(m, addr(i), nonce + 1, balance, code)
      end)

    workers = 4

    1..workers
    |> Task.async_stream(
      fn w ->
        if rem(w, 2) == 0 do
          _ = CAccountMap.difference_full(a, b)
        else
          _ = CAccountMap.difference_full(b, a)
        end

        :ok
      end,
      max_concurrency: workers,
      timeout: 60_000,
      ordered: false
    )
    |> Stream.run()
  end

  defp s_list_diff_compact_vs_live(_round, _ctx) do
    n = :rand.uniform(60) + 20
    live = build_live_state(n)
    compact = State.compact(live)
    compact_nif = State.uncompact(compact).accounts

    fork =
      live
      |> State.clone()
      |> State.storage_put_map(%{
        addr(rem(:rand.uniform(n), n) + 1) => %{
          slot(55_555) => <<55_555::unsigned-size(256)>>
        }
      })

    _ = CAccountMap.difference_full(compact_nif, fork.accounts)
  end

  defp s_list_diff_vs_uncompact(_round, _ctx) do
    compact = build_compact_accounts(:rand.uniform(80) + 20)

    workers = 4

    1..workers
    |> Task.async_stream(
      fn w ->
        if rem(w, 2) == 0 do
          {accounts, _hash} = CAccountMap.uncompact_state(compact)
          _ = CAccountMap.difference_full(accounts, CAccountMap.clone(accounts))
        else
          _ = CAccountMap.uncompact_state(compact)
        end

        :ok
      end,
      max_concurrency: workers,
      timeout: 120_000,
      ordered: false
    )
    |> Stream.run()
  end

  defp s_list_diff_vs_state_lock(_round, _ctx) do
    st = build_live_state(:rand.uniform(60) + 15)
    fork = State.clone(st)

    workers = 6

    1..workers
    |> Task.async_stream(
      fn w ->
        if rem(w, 2) == 0 do
          _ = State.difference(st, fork)
        else
          _ = State.lock(State.clone(st))
        end

        :ok
      end,
      max_concurrency: workers,
      timeout: 60_000,
      ordered: false
    )
    |> Stream.run()
  end

  defp s_list_diff_vs_account_map_get(_round, _ctx) do
    map = build_account_map(:rand.uniform(40) + 10)

    workers = 6

    1..workers
    |> Task.async_stream(
      fn w ->
        if rem(w, 2) == 0 do
          _ = CAccountMap.difference_full(map, CAccountMap.clone(map))
        else
          _ = CAccountMap.get(map, addr(rem(w, 10) + 1))
        end

        :ok
      end,
      max_concurrency: workers,
      timeout: 60_000,
      ordered: false
    )
    |> Stream.run()
  end

  defp s_list_diff_gc_pressure(_round, _ctx) do
    map = build_account_map(:rand.uniform(50) + 10)
    fork = CAccountMap.clone(map)

    for _ <- 1..8 do
      _ = CAccountMap.difference_full(map, fork)
      short = CMerkleTree.new() |> CMerkleTree.clone() |> CMerkleTree.lock()
      _ = short
      :erlang.garbage_collect()
    end
  end

  defp s_prepare_state_composite(_round, _ctx) do
    n = :rand.uniform(80) + 20
    prev = build_live_state(n)

    block =
      prev
      |> State.clone()
      |> then(fn st ->
        i = :rand.uniform(n)

        State.storage_put_map(st, %{
          addr(i) => %{slot(i + 200_000) => <<i * 11::unsigned-size(256)>>}
        })
      end)

    workers = 8

    1..workers
    |> Task.async_stream(
      fn w ->
        case rem(w, 4) do
          0 -> _ = State.difference(prev, block)
          1 -> _ = State.lock(State.clone(block))
          2 -> _ = CAccountMap.to_list(block.accounts)
          _ -> _ = CAccountMap.difference_full(prev.accounts, block.accounts)
        end

        :ok
      end,
      max_concurrency: workers,
      timeout: 120_000,
      ordered: false
    )
    |> Stream.run()
  end

  defp build_account_map(n) do
    Enum.reduce(1..n, CAccountMap.new(), fn i, acc ->
      storage = CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i * 3::unsigned-size(256)>>)
      CAccountMap.put(acc, addr(i), i, i * 1_000, storage, <<i>>)
    end)
  end

  defp build_live_state(n) do
    Enum.reduce(1..n, State.new(), fn i, st ->
      storage = CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i::unsigned-size(256)>>)
      State.set_account(st, addr(i), Account.put_tree(Account.new(nonce: i), storage))
    end)
    |> State.normalize()
  end

  defp read_proc_rss_kb do
    case File.read("/proc/#{System.pid()}/status") do
      {:ok, body} ->
        case Regex.run(~r/VmRSS:\s+(\d+)\s+kB/i, body) do
          [_, n] -> String.to_integer(n)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp s_clone_equivalence(_round, _ctx) do
    n = :rand.uniform(40) + 10

    map =
      Enum.reduce(1..n, CAccountMap.new(), fn i, acc ->
        storage = CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i::unsigned-size(256)>>)
        CAccountMap.put(acc, addr(i), i, i * 500, storage, <<i>>)
      end)

    state = %Chain.State{accounts: map}
    id = addr(:rand.uniform(n))

    mutate = fn st ->
      Chain.State.storage_put_map(st, %{
        id => %{slot(888_888) => <<99::unsigned-size(256)>>}
      })
    end

    fork_a = state |> Chain.State.clone() |> mutate.()
    fork_b = state |> Chain.State.clone() |> mutate.()

    if Chain.State.hash(fork_a) != Chain.State.hash(fork_b) do
      raise "clone fork hash mismatch"
    end

    if CAccountMap.storage_get(map, id, slot(888_888)) != nil do
      raise "clone corrupted parent storage"
    end
  end

  defp check_fuzz_rss(max_delta_kb, round) do
    baseline = Process.get(:cmerkle_fuzz_baseline_rss, 0)
    rss = read_proc_rss_kb()
    delta = rss - baseline
    {_locked, orphans, _shared, _res, _lazy, _eager} = CMerkleTree.nif_stats()

    if orphans > 0 or delta > max_delta_kb do
      IO.puts(:stderr, "FUZZ_RSS_FAIL round=#{round} delta_kb=#{delta} orphans=#{orphans}")
      System.halt(1)
    end
  end
end

try do
  CMerkleFuzz.main(System.argv())
rescue
  e ->
    IO.puts(:stderr, Exception.format(:error, e, __STACKTRACE__))
    IO.puts(:stderr, "FUZZ_ABORT elixir_exception")
    System.halt(1)
end
