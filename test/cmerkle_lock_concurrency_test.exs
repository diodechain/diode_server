# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CMerkleLockConcurrencyTest do
  use ExUnit.Case, async: false

  @moduletag :cmerkle_concurrency
  @moduletag timeout: 300_000

  @tasks 24
  @timeout_ms 120_000

  describe "account_map_lock NIF concurrency" do
    test "concurrent CAccountMap.lock on maps with deduped shared storage tries" do
      map = lock_test_shared_storage_map(60, 5)

      run_parallel(@tasks, fn _ ->
        _ = map |> CAccountMap.clone() |> CAccountMap.lock()
        :ok
      end)
    end

    test "concurrent account_map_lock and storage root / list reads" do
      map = lock_test_shared_storage_map(48, 4)

      lockers = div(@tasks, 2) |> max(1)
      readers = @tasks - lockers

      run_parallel(lockers, fn _ ->
        _ = map |> CAccountMap.clone() |> CAccountMap.lock()
        :ok
      end)

      run_parallel(readers, fn _ ->
        _ = CAccountMap.storage_root_hash(map, <<1::unsigned-size(160)>>)
        _ = CAccountMap.storage_root_hash(map, <<2::unsigned-size(160)>>)
        _ = CAccountMap.storage_to_list(map, <<1::unsigned-size(160)>>)
        _ = CAccountMap.storage_to_list(map, <<2::unsigned-size(160)>>)
        :ok
      end)
    end
  end

  describe "D-C7 native difference_full vs account_map_get" do
    test "concurrent difference_full and get materialize" do
      map = lock_test_shared_storage_map(60, 5)
      fork = CAccountMap.clone(map)

      getters = div(@tasks, 2) |> max(1)
      differ = @tasks - getters

      run_parallel(getters, fn w ->
        _ = CAccountMap.get(map, <<rem(w, 60) + 1::unsigned-size(160)>>)
        :ok
      end)

      run_parallel(differ, fn _ ->
        _ = CAccountMap.difference_full(map, fork)
        :ok
      end)
    end
  end

  describe "D-C8 dual-map difference_full ordering" do
    test "difference_full(A,B) concurrent with difference_full(B,A)" do
      a = lock_test_shared_storage_map(40, 4)
      b = CAccountMap.clone(a)
      b = CAccountMap.put(b, <<3::unsigned-size(160)>>, 99, 99_000, [], <<99>>)

      ab = div(@tasks, 2) |> max(1)
      ba = @tasks - ab

      run_parallel(ab, fn _ ->
        _ = CAccountMap.difference_full(a, b)
        :ok
      end)

      run_parallel(ba, fn _ ->
        _ = CAccountMap.difference_full(b, a)
        :ok
      end)
    end
  end

  defp lock_test_shared_storage_map(account_count, group_size) do
    Enum.reduce(1..account_count, CAccountMap.new(), fn i, map ->
      g = div(i - 1, group_size)
      storage = [{String.pad_leading("g#{g}", 32), Diode.hash("g#{g}")}]

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
