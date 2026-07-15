# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
#
# NIF deadlock / liveness regression tests (see c_src/LOCK_ORDER.md).
defmodule CMerkleNifDeadlockTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

  @moduletag :cmerkle_concurrency

  @tasks 32
  @ops 25
  @timeout_ms 180_000

  @p9_tasks 48
  @p9_ops 40

  describe "D-A1/P9 phased lock_and_difference (nightly regression)" do
    @describetag timeout: 180_000

    test "phase-1 locked clone drop then phase-2 insert and difference load" do
      lockers = div(@p9_tasks, 3) |> max(1)
      differ = @p9_tasks - lockers

      shared = prefilled_tree("s", 100)
      other = prefilled_tree("o", 100)

      run_parallel(lockers, fn _ ->
        _ =
          shared
          |> CMerkleTree.clone()
          |> CMerkleTree.lock()

        :ok
      end)

      :erlang.garbage_collect()

      run_parallel(differ, fn w ->
        Enum.each(1..@p9_ops, fn j ->
          k = String.pad_leading("p9#{w}_#{j}", 32)
          _ = CMerkleTree.insert(shared, k, CMerkleTree.hash("p9#{w}#{j}"))
          _ = CMerkleTree.difference(shared, other)
          _ = CMerkleTree.difference(other, shared)
        end)

        :ok
      end)
    end
  end

  describe "D-A2 leave_lock (GC) vs difference on same tree" do
    test "concurrent disposable trees, GC, and difference on anchor" do
      anchor =
        CMerkleTree.new()
        |> CMerkleTree.insert_items(
          Enum.map(1..80, fn i ->
            {String.pad_leading("a2a#{i}", 32), CMerkleTree.hash("a2a#{i}")}
          end)
        )

      other =
        CMerkleTree.new()
        |> CMerkleTree.insert_items(
          Enum.map(1..80, fn i ->
            {String.pad_leading("a2o#{i}", 32), CMerkleTree.hash("a2o#{i}")}
          end)
        )

      run_parallel(@tasks, fn w ->
        Enum.each(1..@ops, fn j ->
          _ =
            CMerkleTree.new()
            |> CMerkleTree.insert_items(
              Enum.map(1..12, fn k ->
                {String.pad_leading("d#{w}_#{j}_#{k}", 32), CMerkleTree.hash("d#{w}#{j}#{k}")}
              end)
            )

          _ = CMerkleTree.difference(anchor, other)

          if rem(j, 7) == 0 do
            _ =
              anchor
              |> CMerkleTree.clone()
              |> CMerkleTree.lock()
          end
        end)

        if rem(w, 5) == 0, do: :erlang.garbage_collect()
        :ok
      end)
    end
  end

  describe "D-C2 uncompact_state vs storage difference" do
    test "parallel uncompact and per-account storage diffs" do
      n = 200
      compact = build_compact_accounts(n)
      workers = div(@tasks, 2) |> max(1)

      run_parallel(workers, fn i ->
        if rem(i, 2) == 0 do
          {accounts, _store, _hash} = CAccountMap.uncompact_state(compact)
          if CAccountMap.size(accounts) != n, do: raise("size mismatch")
        else
          a =
            CMerkleTree.insert_items(CMerkleTree.new(), [
              {slot(i), <<i::unsigned-size(256)>>},
              {slot(i + 7000), <<i + 1::unsigned-size(256)>>}
            ])

          b =
            CMerkleTree.insert_items(CMerkleTree.new(), [
              {slot(i), <<i + 3::unsigned-size(256)>>},
              {slot(i + 8000), <<i + 2::unsigned-size(256)>>}
            ])

          _ = CMerkleTree.difference(a, b)
        end

        :ok
      end)
    end
  end

  describe "D-D3 block-sync composite" do
    test "concurrent State.difference, lock, and uncompact" do
      n = 150
      prev = build_live_state(n)

      block =
        prev
        |> State.clone()
        |> then(fn st ->
          Enum.reduce(1..40, st, fn i, acc ->
            id = addr(rem(i, n) + 1)
            acc0 = State.account(acc, id)
            tree = Account.tree(acc0)

            tree =
              CMerkleTree.insert(tree, slot(i + 200_000), <<i * 13::unsigned-size(256)>>)

            State.set_account(acc, id, Account.put_tree(acc0, tree))
          end)
        end)

      compact = State.compact(block)
      differ = div(@tasks, 3) |> max(1)
      lockers = div(@tasks, 3) |> max(1)
      uncompactors = @tasks - differ - lockers

      run_parallel(differ, fn _ ->
        _ = State.difference(prev, block)
        :ok
      end)

      run_parallel(lockers, fn _ ->
        _ = State.lock(State.clone(block))
        :ok
      end)

      run_parallel(uncompactors, fn _ ->
        restored = State.uncompact(compact)
        if CAccountMap.size(restored.accounts) != n, do: raise("uncompact size mismatch")
        :ok
      end)
    end
  end

  describe "D-C5 account_map_lock vs clone and difference" do
    test "concurrent bulk lock, clone, and storage difference" do
      n = 120

      map =
        Enum.reduce(1..n, CAccountMap.new(), fn i, acc ->
          storage =
            CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i * 3::unsigned-size(256)>>)

          CAccountMap.put(acc, addr(i), i, i * 1_000, storage, <<i>>)
        end)

      store =
        CMerkleTree.insert_items(CMerkleTree.new(), [
          {slot(99_999), <<99_999::unsigned-size(256)>>}
        ])

      lockers = div(@tasks, 3) |> max(1)
      cloners = div(@tasks, 3) |> max(1)
      differ = @tasks - lockers - cloners

      run_parallel(lockers, fn _ ->
        _ = CAccountMap.lock(map, store)
        :ok
      end)

      run_parallel(cloners, fn w ->
        fork = CAccountMap.clone(map)

        fork =
          CAccountMap.put(
            fork,
            addr(rem(w, n) + 1),
            9_999,
            9_999,
            CMerkleTree.new(),
            <<9_999>>
          )

        if CAccountMap.size(fork) != n, do: raise("clone size mismatch")
        :ok
      end)

      run_parallel(differ, fn i ->
        a = CAccountMap.get(map, addr(rem(i, n) + 1))
        b = CAccountMap.get(map, addr(rem(i + 1, n) + 1))

        case {a, b} do
          {{_, _, sa, _}, {_, _, sb, _}} ->
            _ = CMerkleTree.difference(sa, sb)

          _ ->
            :ok
        end

        :ok
      end)
    end
  end

  describe "D-B2 three-tree difference overlap" do
    test "difference(A,B) concurrent with difference(A,C)" do
      shared =
        CMerkleTree.new()
        |> CMerkleTree.insert_items(
          Enum.map(1..100, fn i ->
            {String.pad_leading("b2s#{i}", 32), CMerkleTree.hash("b2s#{i}")}
          end)
        )

      tb =
        CMerkleTree.new()
        |> CMerkleTree.insert_items(
          Enum.map(1..100, fn i ->
            {String.pad_leading("b2b#{i}", 32), CMerkleTree.hash("b2b#{i}")}
          end)
        )

      tc =
        CMerkleTree.new()
        |> CMerkleTree.insert_items(
          Enum.map(1..100, fn i ->
            {String.pad_leading("b2c#{i}", 32), CMerkleTree.hash("b2c#{i}")}
          end)
        )

      ab = div(@tasks, 2) |> max(1)
      ac = @tasks - ab

      run_parallel(ab, fn _ ->
        Enum.each(1..@ops, fn _ ->
          _ = CMerkleTree.difference(shared, tb)
        end)

        :ok
      end)

      run_parallel(ac, fn _ ->
        Enum.each(1..@ops, fn _ ->
          _ = CMerkleTree.difference(shared, tc)
          _ = CMerkleTree.difference(tb, tc)
        end)

        :ok
      end)
    end
  end

  describe "D-F2 enter_lock canonical ref vs concurrent leave_lock" do
    test "many clones lock same root under difference load" do
      data =
        Enum.map(1..100, fn i ->
          {String.pad_leading("f2#{i}", 32), CMerkleTree.hash("f2#{i}")}
        end)

      base = CMerkleTree.new() |> CMerkleTree.insert_items(data)
      expected_root = CMerkleTree.root_hash(base)

      other =
        CMerkleTree.new()
        |> CMerkleTree.insert_items(
          Enum.map(1..100, fn i ->
            {String.pad_leading("f2o#{i}", 32), CMerkleTree.hash("f2o#{i}")}
          end)
        )

      lockers = div(@tasks, 2) |> max(1)
      differ = @tasks - lockers

      run_parallel(lockers, fn _ ->
        locked =
          base
          |> CMerkleTree.clone()
          |> CMerkleTree.lock()

        if CMerkleTree.root_hash(locked) != expected_root, do: raise("root mismatch")
        :ok
      end)

      run_parallel(differ, fn w ->
        Enum.each(1..@ops, fn j ->
          k = String.pad_leading("f2m#{w}_#{j}", 32)
          _ = CMerkleTree.insert(base, k, CMerkleTree.hash("m#{w}#{j}"))
          _ = CMerkleTree.difference(base, other)
        end)

        :ok
      end)
    end
  end

  describe "D-D7 prepare_state composite (us1-shaped)" do
    test "concurrent list_difference, to_list, and State.lock" do
      n = 100
      prev = build_live_state(n) |> State.normalize()

      block =
        prev
        |> State.clone()
        |> then(fn st ->
          Enum.reduce(1..20, st, fn i, acc ->
            id = addr(rem(i, n) + 1)
            acc0 = State.account(acc, id)
            tree = Account.tree(acc0)

            tree =
              CMerkleTree.insert(tree, slot(i + 300_000), <<i * 13::unsigned-size(256)>>)

            State.set_account(acc, id, Account.put_tree(acc0, tree))
          end)
        end)

      differ = div(@tasks, 4) |> max(1)
      lockers = div(@tasks, 4) |> max(1)
      legacy = div(@tasks, 4) |> max(1)
      native = @tasks - differ - lockers - legacy

      run_parallel(differ, fn _ ->
        _ = State.difference(prev, block)
        :ok
      end)

      run_parallel(lockers, fn _ ->
        _ = State.lock(State.clone(block))
        :ok
      end)

      run_parallel(legacy, fn _ ->
        _ = CAccountMap.to_list(block.accounts)
        :ok
      end)

      run_parallel(native, fn _ ->
        _ = CAccountMap.list_difference(prev.accounts, block.accounts)
        :ok
      end)
    end
  end

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp slot(i), do: <<i::unsigned-size(256)>>

  defp prefilled_tree(prefix, n) do
    CMerkleTree.new()
    |> CMerkleTree.insert_items(
      Enum.map(1..n, fn i ->
        {String.pad_leading("#{prefix}#{i}", 32), CMerkleTree.hash("#{prefix}#{i}")}
      end)
    )
  end

  defp build_compact_accounts(n) do
    for i <- 1..n, into: %{} do
      tree =
        CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i * 7::unsigned-size(256)>>)

      acc = %Account{nonce: i, balance: i * 1_000, storage_root: tree, code: <<i>>}
      {addr(i), Account.compact(acc)}
    end
  end

  defp build_live_state(n) do
    Enum.reduce(1..n, State.new(), fn i, st ->
      tree =
        CMerkleTree.insert_items(CMerkleTree.new(), [
          {slot(i), <<i * 2::unsigned-size(256)>>}
        ])

      acc = %Account{nonce: i, balance: i * 1_000, storage_root: tree, code: <<i>>}
      State.set_account(st, addr(i), acc)
    end)
  end

  defp run_parallel(count, fun) do
    result =
      1..count
      |> Task.async_stream(
        fun,
        max_concurrency: count,
        timeout: @timeout_ms,
        ordered: false
      )
      |> Enum.to_list()

    assert length(result) == count
    assert Enum.all?(result, fn {:ok, :ok} -> true end)
  end
end
