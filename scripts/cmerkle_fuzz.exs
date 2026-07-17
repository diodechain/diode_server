# CAccountMap NIF stress / fuzz harness (map + storage list APIs only).
# Run from repo root (use --no-start to avoid booting the full Diode app):
#   mix run --no-start scripts/cmerkle_fuzz.exs -- --iterations 10000 --seed 42
# Environment (optional): MERKLE_FUZZ_ITERATIONS, MERKLE_FUZZ_SEED, MERKLE_FUZZ_MAX_KEYS
#
# Options:
#   --iterations N   number of fuzz rounds (default: 0 = run until SIGINT)
#   --seed N         RNG seed for reproducibility (default: random)
#   --max-keys N     cap accounts / slots per scenario (default: 900)
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
    === CAccountMap fuzz ===
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
    scenario = ctx[:scenario] || :rand.uniform(21)

    case scenario do
      1 -> s_account_map_uncompact(round, ctx)
      2 -> s_account_map_clone_mutate(round, ctx)
      3 -> s_uncompact_and_map_diff(round, ctx)
      4 -> s_account_get_materialize_diff(round, ctx)
      5 -> s_gc_during_map_lock_diff(round, ctx)
      6 -> s_state_lock_clone_mutate(round, ctx)
      7 -> s_account_map_lock_bulk(round, ctx)
      8 -> s_account_map_lock_concurrent(round, ctx)
      9 -> s_account_map_list_diff_large_compact(round, ctx)
      10 -> s_list_diff_vs_to_list(round, ctx)
      11 -> s_list_diff_vs_account_map_lock(round, ctx)
      12 -> s_list_diff_vs_clone_put(round, ctx)
      13 -> s_list_diff_vs_storage_apis(round, ctx)
      14 -> s_dual_map_list_diff_order(round, ctx)
      15 -> s_list_diff_compact_vs_live(round, ctx)
      16 -> s_list_diff_vs_uncompact(round, ctx)
      17 -> s_list_diff_vs_state_lock(round, ctx)
      18 -> s_list_diff_vs_account_map_get(round, ctx)
      19 -> s_list_diff_gc_pressure(round, ctx)
      20 -> s_prepare_state_composite(round, ctx)
      21 -> s_clone_equivalence(round, ctx)
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

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp slot(i), do: <<i::unsigned-size(256)>>

  defp storage_list(i, mult \\ 3) do
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

  defp build_account_map(n) do
    Enum.reduce(1..n, CAccountMap.new(), fn i, acc ->
      CAccountMap.put(acc, addr(i), i, i * 1_000, storage_list(i), <<i>>)
    end)
  end

  defp build_live_state(n) do
    Enum.reduce(1..n, State.new(), fn i, st ->
      State.set_account(st, addr(i), %{
        Account.new(nonce: i)
        | storage_root: [{slot(i), <<i::unsigned-size(256)>>}],
          map_backed: false,
          root_hash: nil
      })
    end)
    |> State.normalize()
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
      |> CAccountMap.put(addr(1), 99, 99_000, [], <<99>>)

    _ = CAccountMap.to_list(accounts)

    if CAccountMap.size(fork) != n, do: raise("fork size mismatch")
  end

  defp s_uncompact_and_map_diff(_round, _ctx) do
    n = :rand.uniform(60) + 20
    compact = build_compact_accounts(n)

    parent = Task.async(fn -> CAccountMap.uncompact_state(compact) end)

    diffs =
      1..4
      |> Task.async_stream(
        fn i ->
          a = build_account_map(10 + i)
          b = CAccountMap.clone(a)

          b =
            CAccountMap.storage_put_map(b, %{
              addr(1) => %{slot(i + 1000) => <<i + 1::unsigned-size(256)>>}
            })

          CAccountMap.difference_full(a, b)
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

    _ = CAccountMap.storage_get(accounts, addr(1), slot(1))
    _ = CAccountMap.storage_root_hash(accounts, addr(1))
    _ = CAccountMap.storage_to_list(accounts, addr(1))
    _ = CAccountMap.get(accounts, addr(2))
  end

  defp s_gc_during_map_lock_diff(_round, _ctx) do
    map = build_account_map(:rand.uniform(60) + 20)
    fork = CAccountMap.clone(map)

    1..6
    |> Task.async_stream(
      fn w ->
        if rem(w, 2) == 0 do
          _ = CAccountMap.lock(map)
        else
          _ = CAccountMap.difference_full(map, fork)
        end

        :ok
      end,
      max_concurrency: 6,
      timeout: 60_000,
      ordered: false
    )
    |> Stream.run()

    _ = CAccountMap.new() |> CAccountMap.lock()
    :erlang.garbage_collect()
  end

  defp s_state_lock_clone_mutate(_round, _ctx) do
    n = :rand.uniform(60) + 10
    compact = build_compact_accounts(n)

    parent =
      compact
      |> then(fn accounts -> %State{accounts: accounts} end)
      |> State.uncompact()

    parent =
      if :rand.uniform(2) == 1 do
        State.normalize(parent)
      else
        parent
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
        CAccountMap.put(acc, addr(i), i, i * 1_000, storage_list(g + 1, 1), <<i>>)
      end)

    _ = CAccountMap.lock(map)

    fork =
      map
      |> CAccountMap.clone()
      |> CAccountMap.put(addr(1), 77, 77_000, [], <<77>>)

    if CAccountMap.size(fork) != n, do: raise("fork size mismatch")

    if CAccountMap.get(map, addr(1)) == CAccountMap.get(fork, addr(1)),
      do: raise("parent mutated")
  end

  defp s_account_map_lock_concurrent(_round, _ctx) do
    n = :rand.uniform(60) + 20
    map = build_account_map(n)
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
          storage = [{slot(w + i), <<w::unsigned-size(256)>>}]
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

  defp s_list_diff_vs_storage_apis(_round, _ctx) do
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
      short = CAccountMap.new() |> CAccountMap.lock()
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

  defp s_clone_equivalence(_round, _ctx) do
    n = :rand.uniform(40) + 10
    map = build_account_map(n)
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

  defp check_fuzz_rss(max_delta_kb, round) do
    baseline = Process.get(:cmerkle_fuzz_baseline_rss, 0)
    rss = read_proc_rss_kb()
    delta = rss - baseline
    {_locked, orphans, _shared, _res} = CMerkleTree.nif_stats()

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
