# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CMerkleAccountMapDiffTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

  @moduletag timeout: 300_000

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp slot(i), do: <<i::unsigned-size(256)>>

  defp build_map(n, mutate \\ nil) do
    Enum.reduce(1..n, CAccountMap.new(), fn i, acc ->
      storage =
        CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i * 3::unsigned-size(256)>>)

      nonce = if mutate == {:nonce, i}, do: i + 1000, else: i
      balance = if mutate == {:balance, i}, do: i * 9_999, else: i * 1_000
      code = if mutate == {:code, i}, do: <<i, i + 1>>, else: <<i>>

      CAccountMap.put(acc, addr(i), nonce, balance, storage, code)
    end)
  end

  defp full_addrs(map_a, map_b) do
    CAccountMap.difference_full(map_a, map_b)
    |> Enum.map(fn {addr, _, _, _} -> addr end)
    |> Enum.sort()
  end

  defp assert_difference_full_shape(map_a, map_b) do
    full = CAccountMap.difference_full(map_a, map_b)
    assert is_list(full)

    for {addr, _side_a, _side_b, storage_diff} <- full do
      assert byte_size(addr) == 20
      assert is_list(storage_diff) or is_map(storage_diff)
      in_a = CAccountMap.get(map_a, addr) != :undefined
      in_b = CAccountMap.get(map_b, addr) != :undefined
      assert in_a or in_b
    end

    full
  end

  describe "difference_full" do
    test "empty maps" do
      a = CAccountMap.new()
      b = CAccountMap.new()
      assert CAccountMap.difference_full(a, b) == []
    end

    test "identical maps" do
      a = build_map(40)
      b = CAccountMap.clone(a)
      assert CAccountMap.difference_full(a, b) == []
    end

    test "same shared map resource" do
      a = build_map(10)
      assert CAccountMap.difference_full(a, a) == []
    end

    test "add-only and delete-only accounts" do
      a = build_map(30)
      b = build_map(35)
      assert full_addrs(a, b) == Enum.map(31..35, &addr/1) |> Enum.sort()
      assert_difference_full_shape(a, b)

      c = build_map(20)
      assert full_addrs(a, c) == Enum.map(21..30, &addr/1) |> Enum.sort()
      assert_difference_full_shape(a, c)
    end

    test "scalar field mutations" do
      base = build_map(50)

      for mutate <- [{:nonce, 3}, {:balance, 7}, {:code, 11}] do
        fork = CAccountMap.clone(base)
        {kind, i} = mutate
        storage = CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i::unsigned-size(256)>>)

        fork =
          case kind do
            :nonce -> CAccountMap.put(fork, addr(i), i + 500, i * 1_000, storage, <<i>>)
            :balance -> CAccountMap.put(fork, addr(i), i, i * 50_000, storage, <<i>>)
            :code -> CAccountMap.put(fork, addr(i), i, i * 1_000, storage, <<99, 88>>)
          end

        assert full_addrs(base, fork) == [addr(i)]
        assert_difference_full_shape(base, fork)
      end
    end

    test "storage mutation" do
      a = build_map(25)
      b = CAccountMap.clone(a)
      id = addr(5)

      b =
        CAccountMap.storage_put_map(b, %{
          id => %{slot(99_999) => <<99_999::unsigned-size(256)>>}
        })

      assert full_addrs(a, b) == [id]
      assert_difference_full_shape(a, b)
      assert CAccountMap.storage_get(b, id, slot(99_999)) == <<99_999::unsigned-size(256)>>
      assert CAccountMap.storage_get(a, id, slot(99_999)) == nil
    end

    test "shared storage trie across accounts" do
      storage =
        CMerkleTree.insert_items(CMerkleTree.new(), [
          {slot(1), <<1::unsigned-size(256)>>}
        ])

      a =
        Enum.reduce(1..12, CAccountMap.new(), fn i, acc ->
          CAccountMap.put(acc, addr(i), i, i * 10, storage, <<>>)
        end)

      b = CAccountMap.clone(a)
      assert CAccountMap.difference_full(a, b) == []

      b = CAccountMap.put(b, addr(3), 99, 999, storage, <<1>>)
      assert full_addrs(a, b) == [addr(3)]
      assert_difference_full_shape(a, b)
    end

    test "compact maps via State.compact" do
      live =
        State.new()
        |> then(fn st ->
          Enum.reduce(1..80, st, fn i, acc ->
            storage = CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i::unsigned-size(256)>>)
            acc0 = Account.put_tree(Account.new(nonce: i, balance: i), storage)
            State.set_account(acc, addr(i), acc0)
          end)
        end)

      compact = State.compact(live)
      compact_nif = State.uncompact(compact).accounts

      fork =
        live
        |> State.clone()
        |> State.storage_put_map(%{
          addr(10) => %{slot(50_000) => <<50_000::unsigned-size(256)>>}
        })

      assert full_addrs(compact_nif, fork.accounts) == [addr(10)]
      assert_difference_full_shape(compact_nif, fork.accounts)
      assert CAccountMap.difference_full(compact_nif, live.accounts) == []
    end

    @tag :slow
    test "randomized difference_full consistency" do
      for seed <- 1..50 do
        :rand.seed(:exsss, {seed, seed, seed})
        n = :rand.uniform(120) + 5
        a = build_map(n)
        b = CAccountMap.clone(a)

        mutations = :rand.uniform(15) + 1

        b =
          Enum.reduce(1..mutations, b, fn _, acc ->
            i = :rand.uniform(n)
            id = addr(i)

            case :rand.uniform(4) do
              1 ->
                CAccountMap.delete(acc, id)

              2 ->
                storage =
                  CMerkleTree.insert(
                    CMerkleTree.new(),
                    slot(i + 10_000),
                    <<i::unsigned-size(256)>>
                  )

                CAccountMap.put(acc, id, i + 1, i * 2_000, storage, <<i>>)

              _ ->
                case CAccountMap.get(acc, id) do
                  :undefined ->
                    acc

                  {_nonce, _balance, _root, _code} ->
                    CAccountMap.storage_put_map(acc, %{
                      id => %{slot(i + 20_000) => <<i * 2::unsigned-size(256)>>}
                    })
                end
            end
          end)

        full = assert_difference_full_shape(a, b)

        if CAccountMap.root_hash(a) == CAccountMap.root_hash(b) do
          assert full == []
        else
          assert full != []
        end
      end
    end
  end

  describe "Chain.State.difference round-trip smoke" do
    test "native path matches apply_difference" do
      prev =
        State.new()
        |> then(fn st ->
          Enum.reduce(1..30, st, fn i, acc ->
            storage = CMerkleTree.insert(CMerkleTree.new(), slot(i), <<i::unsigned-size(256)>>)
            State.set_account(acc, addr(i), Account.put_tree(Account.new(nonce: i), storage))
          end)
        end)

      next =
        prev
        |> State.clone()
        |> State.storage_put_map(%{
          addr(7) => %{slot(77_777) => <<77_777::unsigned-size(256)>>}
        })

      delta = State.difference(prev, next)

      restored =
        prev
        |> State.clone()
        |> State.apply_difference(delta)
        |> State.normalize()

      assert State.hash(restored) == State.hash(next)
    end
  end
end
