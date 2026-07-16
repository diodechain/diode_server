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
  @timeout_ms 180_000

  describe "D-C2 uncompact_state vs storage difference" do
    test "parallel uncompact and per-account storage diffs" do
      n = 200
      compact = build_compact_accounts(n)
      workers = div(@tasks, 2) |> max(1)

      run_parallel(workers, fn i ->
        if rem(i, 2) == 0 do
          {accounts, _hash} = CAccountMap.uncompact_state(compact)
          if CAccountMap.size(accounts) != n, do: raise("size mismatch")
        else
          a =
            CAccountMap.new()
            |> CAccountMap.put(
              addr(i),
              i,
              i * 100,
              [
                {slot(i), <<i::unsigned-size(256)>>},
                {slot(i + 7000), <<i + 1::unsigned-size(256)>>}
              ],
              <<i>>
            )

          b =
            CAccountMap.new()
            |> CAccountMap.put(
              addr(i),
              i,
              i * 100,
              [
                {slot(i), <<i + 3::unsigned-size(256)>>},
                {slot(i + 8000), <<i + 2::unsigned-size(256)>>}
              ],
              <<i>>
            )

          _ = CAccountMap.difference_full(a, b)
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

            State.storage_put_map(acc, %{
              id => %{slot(i + 200_000) => <<i * 13::unsigned-size(256)>>}
            })
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
          storage = [{slot(i), <<i * 3::unsigned-size(256)>>}]
          CAccountMap.put(acc, addr(i), i, i * 1_000, storage, <<i>>)
        end)

      lockers = div(@tasks, 3) |> max(1)
      cloners = div(@tasks, 3) |> max(1)
      differ = @tasks - lockers - cloners

      run_parallel(lockers, fn _ ->
        _ = CAccountMap.lock(map)
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
            [],
            <<9_999>>
          )

        if CAccountMap.size(fork) != n, do: raise("clone size mismatch")
        :ok
      end)

      run_parallel(differ, fn i ->
        a = addr(rem(i, n) + 1)
        b = addr(rem(i + 1, n) + 1)
        _ = CAccountMap.get(map, a)
        _ = CAccountMap.get(map, b)
        _ = CAccountMap.storage_root_hash(map, a)
        _ = CAccountMap.storage_root_hash(map, b)
        _ = CAccountMap.storage_to_list(map, a)
        :ok
      end)
    end
  end

  describe "D-D7 prepare_state composite (us1-shaped)" do
    test "concurrent difference_full, to_list, and State.lock" do
      n = 100
      prev = build_live_state(n) |> State.normalize()

      block =
        prev
        |> State.clone()
        |> then(fn st ->
          Enum.reduce(1..20, st, fn i, acc ->
            id = addr(rem(i, n) + 1)

            State.storage_put_map(acc, %{
              id => %{slot(i + 300_000) => <<i * 13::unsigned-size(256)>>}
            })
          end)
        end)

      differ = div(@tasks, 4) |> max(1)
      lockers = div(@tasks, 4) |> max(1)
      listers = div(@tasks, 4) |> max(1)
      native = @tasks - differ - lockers - listers

      run_parallel(differ, fn _ ->
        _ = State.difference(prev, block)
        :ok
      end)

      run_parallel(lockers, fn _ ->
        _ = State.lock(State.clone(block))
        :ok
      end)

      run_parallel(listers, fn _ ->
        _ = CAccountMap.to_list(block.accounts)
        :ok
      end)

      run_parallel(native, fn _ ->
        _ = CAccountMap.difference_full(prev.accounts, block.accounts)
        :ok
      end)
    end
  end

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp slot(i), do: <<i::unsigned-size(256)>>

  defp build_compact_accounts(n) do
    Enum.reduce(1..n, State.new(), fn i, st ->
      acc = %Account{
        nonce: i,
        balance: i * 1_000,
        storage_root: [{slot(i), <<i * 7::unsigned-size(256)>>}],
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
        storage_root: [{slot(i), <<i * 2::unsigned-size(256)>>}],
        code: <<i>>
      }

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
