# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CMerkleLockConcurrencyTest do
  use ExUnit.Case, async: false

  @moduletag :cmerkle_concurrency
  @moduletag timeout: 300_000

  @tasks 24
  @ops 30
  @timeout_ms 120_000

  describe "lock + difference concurrency (production deadlock regression)" do
    test "concurrent lock/1 on clones with identical root (enter_lock dedup)" do
      data =
        Enum.map(1..80, fn i ->
          {String.pad_leading("L#{i}", 32), CMerkleTree.hash("lock#{i}")}
        end)

      base = CMerkleTree.new() |> CMerkleTree.insert_items(data)

      run_parallel(@tasks, fn _ ->
        _ =
          base
          |> CMerkleTree.clone()
          |> CMerkleTree.lock()

        :ok
      end)
    end

    test "concurrent difference while locking cloned trees with shared roots" do
      ta =
        CMerkleTree.new()
        |> CMerkleTree.insert_items(
          Enum.map(1..120, fn i ->
            {String.pad_leading("da#{i}", 32), CMerkleTree.hash("da#{i}")}
          end)
        )

      tb =
        CMerkleTree.new()
        |> CMerkleTree.insert_items(
          Enum.map(1..120, fn i ->
            {String.pad_leading("db#{i}", 32), CMerkleTree.hash("db#{i}")}
          end)
        )

      base =
        CMerkleTree.new()
        |> CMerkleTree.insert_items(
          Enum.map(1..100, fn i ->
            {String.pad_leading("sh#{i}", 32), CMerkleTree.hash("sh#{i}")}
          end)
        )

      run_parallel(@tasks, fn w ->
        if rem(w, 3) == 0 do
          _ = CMerkleTree.difference(ta, tb)
        else
          _ =
            base
            |> CMerkleTree.clone()
            |> CMerkleTree.lock()

          Enum.each(1..@ops, fn j ->
            k = String.pad_leading("m#{w}_#{j}", 32)
            _ = CMerkleTree.insert(ta, k, CMerkleTree.hash("v#{w}#{j}"))
            _ = CMerkleTree.difference(ta, tb)
          end)
        end

        :ok
      end)
    end

    test "interleaved lock, difference, and mutate (P5 + P6 combined)" do
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

      mutators = div(@tasks, 3) |> max(1)
      lockers = div(@tasks, 3) |> max(1)
      differ = @tasks - mutators - lockers

      run_parallel(mutators, fn w ->
        Enum.each(1..@ops, fn j ->
          k = String.pad_leading("mut#{w}_#{j}", 32)
          _ = CMerkleTree.insert(ta, k, CMerkleTree.hash("mut#{w}#{j}"))
        end)

        :ok
      end)

      run_parallel(lockers, fn _ ->
        _ =
          ta
          |> CMerkleTree.clone()
          |> CMerkleTree.lock()

        :ok
      end)

      run_parallel(differ, fn _ ->
        _ = CMerkleTree.difference(ta, tb)
        _ = CMerkleTree.difference(tb, ta)
        :ok
      end)
    end

    test "lock dedup still shares canonical root across clones" do
      data =
        Enum.map(1..40, fn i ->
          {String.pad_leading("d#{i}", 32), CMerkleTree.hash("d#{i}")}
        end)

      base = CMerkleTree.new() |> CMerkleTree.insert_items(data)
      expected_root = CMerkleTree.root_hash(base)

      locked =
        1..8
        |> Enum.map(fn _ ->
          base |> CMerkleTree.clone() |> CMerkleTree.lock()
        end)

      for tree <- locked do
        assert CMerkleTree.root_hash(tree) == expected_root
      end
    end
  end

  describe "account_map_lock NIF concurrency" do
    test "concurrent CAccountMap.lock on maps with deduped shared storage tries" do
      map = lock_test_shared_storage_map(60, 5)

      _store =
        CMerkleTree.insert_items(CMerkleTree.new(), [
          {String.pad_leading("store", 32), CMerkleTree.hash("store")}
        ])

      run_parallel(@tasks, fn _ ->
        _ = map |> CAccountMap.clone() |> CAccountMap.lock()
        :ok
      end)
    end

    test "concurrent account_map_lock and storage difference" do
      map = lock_test_shared_storage_map(48, 4)

      {_, _, storage_a, _} = CAccountMap.get(map, <<1::unsigned-size(160)>>)
      {_, _, storage_b, _} = CAccountMap.get(map, <<2::unsigned-size(160)>>)

      lockers = div(@tasks, 2) |> max(1)
      differ = @tasks - lockers

      run_parallel(lockers, fn _ ->
        _ = map |> CAccountMap.clone() |> CAccountMap.lock()
        :ok
      end)

      run_parallel(differ, fn _ ->
        _ = CMerkleTree.difference(storage_a, storage_b)
        _ = CMerkleTree.difference(storage_b, storage_a)
        :ok
      end)
    end
  end

  describe "D-C7 native list_difference vs account_map_get" do
    test "concurrent list_difference and get materialize" do
      map = lock_test_shared_storage_map(60, 5)
      fork = CAccountMap.clone(map)

      getters = div(@tasks, 2) |> max(1)
      differ = @tasks - getters

      run_parallel(getters, fn w ->
        _ = CAccountMap.get(map, <<rem(w, 60) + 1::unsigned-size(160)>>)
        :ok
      end)

      run_parallel(differ, fn _ ->
        _ = CAccountMap.list_difference(map, fork)
        :ok
      end)
    end
  end

  describe "D-C8 dual-map list_difference ordering" do
    test "list_difference(A,B) concurrent with list_difference(B,A)" do
      a = lock_test_shared_storage_map(40, 4)
      b = CAccountMap.clone(a)
      b = CAccountMap.put(b, <<3::unsigned-size(160)>>, 99, 99_000, CMerkleTree.new(), <<99>>)

      ab = div(@tasks, 2) |> max(1)
      ba = @tasks - ab

      run_parallel(ab, fn _ ->
        _ = CAccountMap.list_difference(a, b)
        :ok
      end)

      run_parallel(ba, fn _ ->
        _ = CAccountMap.list_difference(b, a)
        :ok
      end)
    end
  end

  defp lock_test_shared_storage_map(account_count, group_size) do
    Enum.reduce(1..account_count, CAccountMap.new(), fn i, map ->
      storage =
        CMerkleTree.insert_items(CMerkleTree.new(), [
          {String.pad_leading("g#{div(i - 1, group_size)}", 32),
           CMerkleTree.hash("g#{div(i - 1, group_size)}")}
        ])

      CAccountMap.put(map, <<i::unsigned-size(160)>>, i, i * 1_000, storage, <<i>>)
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

    for {:ok, :ok} <- result do
      :ok
    end

    assert length(result) == count
    assert Enum.all?(result, fn {:ok, :ok} -> true end)
  end
end
