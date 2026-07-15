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

  defp legacy_diff(map_a, map_b) do
    CMerkleTree.list_difference(
      CAccountMap.to_account_list(map_a),
      CAccountMap.to_account_list(map_b)
    )
  end

  defp assert_diff_equivalent(map_a, map_b) do
    native = CAccountMap.list_difference(map_a, map_b)
    legacy = legacy_diff(map_a, map_b)

    assert Map.keys(native) |> Enum.sort() == Map.keys(legacy) |> Enum.sort()

    for key <- Map.keys(native) do
      {na, nb} = native[key]
      {la, lb} = legacy[key]
      assert account_equal?(na, la)
      assert account_equal?(nb, lb)
    end
  end

  defp account_equal?(nil, nil), do: true

  defp account_equal?(%Account{} = a, %Account{} = b) do
    a.nonce == b.nonce && a.balance == b.balance && a.code == b.code &&
      Account.root_hash(a) == Account.root_hash(b)
  end

  defp account_equal?(a, b), do: a == b

  describe "native vs legacy list_difference equivalence" do
    test "empty maps" do
      a = CAccountMap.new()
      b = CAccountMap.new()
      assert_diff_equivalent(a, b)
      assert CAccountMap.list_difference(a, b) == %{}
    end

    test "identical maps" do
      a = build_map(40)
      b = CAccountMap.clone(a)
      assert_diff_equivalent(a, b)
      assert CAccountMap.list_difference(a, b) == %{}
    end

    test "same shared map resource" do
      a = build_map(10)
      assert CAccountMap.list_difference(a, a) == %{}
    end

    test "add-only and delete-only accounts" do
      a = build_map(30)
      b = build_map(35)
      assert_diff_equivalent(a, b)

      c = build_map(20)
      assert_diff_equivalent(a, c)
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

        assert_diff_equivalent(base, fork)
      end
    end

    test "storage mutation" do
      a = build_map(25)
      b = CAccountMap.clone(a)
      id = addr(5)
      {nonce, balance, storage, code} = CAccountMap.get(b, id)

      storage =
        CMerkleTree.insert(
          CMerkleTree.clone(storage),
          slot(99_999),
          <<99_999::unsigned-size(256)>>
        )

      b = CAccountMap.put(b, id, nonce, balance, storage, code)
      assert_diff_equivalent(a, b)
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
      assert_diff_equivalent(a, b)

      b = CAccountMap.put(b, addr(3), 99, 999, storage, <<1>>)
      refute CAccountMap.list_difference(a, b) == %{}
      assert_diff_equivalent(a, b)
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
        |> then(fn st ->
          acc = State.account(st, addr(10))

          tree =
            Account.tree(acc)
            |> CMerkleTree.insert(slot(50_000), <<50_000::unsigned-size(256)>>)

          State.set_account(st, addr(10), Account.put_tree(acc, tree))
        end)

      assert_diff_equivalent(compact_nif, fork.accounts)
      assert_diff_equivalent(compact_nif, live.accounts)
    end

    @tag :slow
    test "randomized equivalence property" do
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
                {nonce, balance, storage, code} = CAccountMap.get(acc, id)

                storage =
                  CMerkleTree.insert(
                    CMerkleTree.clone(storage),
                    slot(i + 20_000),
                    <<i * 2::unsigned-size(256)>>
                  )

                CAccountMap.put(acc, id, nonce, balance, storage, code)
            end
          end)

        assert_diff_equivalent(a, b)
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
        |> then(fn st ->
          acc = State.account(st, addr(7))

          tree =
            Account.tree(acc)
            |> CMerkleTree.insert(slot(77_777), <<77_777::unsigned-size(256)>>)

          State.set_account(st, addr(7), Account.put_tree(acc, tree))
        end)

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
