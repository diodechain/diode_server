# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
#
# Lifetime / refcount regression tests for CAccountMap NIF resources.
# Targets bugs like premature SharedState deletion while merkletree resources
# are still alive (ethr_mutex_lock EINVAL on destroyed mutex).
defmodule CAccountMapLifetimeTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

  @moduletag timeout: 120_000

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp slot(i), do: <<i::unsigned-size(256)>>

  defp val(i), do: <<i + 1::unsigned-size(256)>>

  defp force_gc(rounds \\ 3) do
    for _ <- 1..rounds, do: :erlang.garbage_collect()
  end

  # Run a callback with short-lived values, then collect clone resources.
  defp ephemeral(fun) when is_function(fun, 0) do
    result = fun.()
    force_gc()
    result
  end

  defp sample_account(n) do
    tree =
      CMerkleTree.insert_items(CMerkleTree.new(), [
        {slot(n), val(n)}
      ])

    %Account{nonce: n, balance: n * 1_000, storage_root: tree, code: <<n>>}
  end

  defp put_sample(map, i) do
    CAccountMap.put_account(map, addr(i), sample_account(i))
  end

  defp populate_map(n_accounts) do
    Enum.reduce(1..n_accounts, CAccountMap.new(), &put_sample(&2, &1))
  end

  defp assert_storage_usable(storage) do
    hash = CMerkleTree.root_hash(storage)
    assert is_binary(hash) and byte_size(hash) > 0

    updated =
      CMerkleTree.insert_items(storage, [
        {slot(9_999), val(9_999)}
      ])

    assert is_binary(CMerkleTree.root_hash(updated))
  end

  # CAccountMap.clone now produces writable (locked = false) storage tries that are
  # distinct resources from the parent's, so account entries must be compared by
  # value (storage root_hash) rather than by resource identity.
  defp entry_value(:undefined), do: :undefined

  defp entry_value({nonce, balance, storage, code}) do
    {nonce, balance, CMerkleTree.root_hash(storage), code}
  end

  describe "clone GC must not corrupt parent storage" do
    test "dropping a single clone leaves parent storage tries lockable" do
      base = put_sample(CAccountMap.new(), 5)

      ephemeral(fn ->
        fork = CAccountMap.clone(base)

        assert entry_value(CAccountMap.get(fork, addr(5))) ==
                 entry_value(CAccountMap.get(base, addr(5)))
      end)

      {_, _, storage, _} = CAccountMap.get(base, addr(5))
      assert_storage_usable(storage)
    end

    test "many ephemeral clones with reads between GC rounds" do
      base = populate_map(8)

      for round <- 1..40 do
        ephemeral(fn ->
          fork = CAccountMap.clone(base)
          assert CAccountMap.size(fork) == 8
          assert length(CAccountMap.to_list(fork)) == 8

          for i <- 1..8 do
            assert entry_value(CAccountMap.get(fork, addr(i))) ==
                     entry_value(CAccountMap.get(base, addr(i)))
          end
        end)

        if rem(round, 5) == 0 do
          force_gc()
        end
      end

      for i <- 1..8 do
        {_, _, storage, _} = CAccountMap.get(base, addr(i))
        assert_storage_usable(storage)
      end
    end

    test "State.clone churn like block sync without mutating fork" do
      state =
        State.new()
        |> State.set_account(addr(1), sample_account(1))
        |> State.set_account(addr(2), sample_account(2))

      for _ <- 1..60 do
        ephemeral(fn ->
          fork = State.clone(state)
          assert State.hash(fork) == State.hash(state)
        end)
      end

      acc = State.account(state, addr(1))
      assert_storage_usable(Account.tree(acc))
      assert State.hash(state) == State.hash(State.clone(state))
    end
  end

  describe "shared storage pointers across accounts" do
    test "two accounts referencing the same storage trie survive clone GC" do
      storage =
        CMerkleTree.insert_items(CMerkleTree.new(), [
          {slot(1), val(1)},
          {slot(2), val(2)}
        ])

      map =
        CAccountMap.new()
        |> CAccountMap.put(addr(10), 1, 100, storage, <<10>>)
        |> CAccountMap.put(addr(11), 2, 200, storage, <<11>>)

      assert CAccountMap.size(map) == 2

      for _ <- 1..30 do
        ephemeral(fn ->
          fork = CAccountMap.clone(map)
          assert CAccountMap.size(fork) == 2
        end)
      end

      {_, _, storage_a, _} = CAccountMap.get(map, addr(10))
      {_, _, storage_b, _} = CAccountMap.get(map, addr(11))
      assert storage_a == storage_b
      assert_storage_usable(storage_a)
    end

    test "shared storage with fork mutation splits only the mutated branch" do
      storage = CMerkleTree.insert_items(CMerkleTree.new(), [{slot(1), val(1)}])

      map =
        CAccountMap.new()
        |> CAccountMap.put(addr(20), 1, 100, storage, <<20>>)
        |> CAccountMap.put(addr(21), 2, 200, storage, <<21>>)

      ephemeral(fn ->
        fork =
          map
          |> CAccountMap.clone()
          |> CAccountMap.put(
            addr(20),
            9,
            900,
            CMerkleTree.insert_items(storage, [{slot(99), val(99)}]),
            <<99>>
          )

        assert {9, 900, _, <<99>>} = CAccountMap.get(fork, addr(20))
        assert {1, 100, _, <<20>>} = CAccountMap.get(map, addr(20))
        assert {2, 200, _, <<21>>} = CAccountMap.get(map, addr(21))
      end)

      {_, _, parent_storage, _} = CAccountMap.get(map, addr(20))
      assert_storage_usable(parent_storage)
    end
  end

  describe "COW fork operations after clone drop" do
    test "delete on fork after dropping sibling clones" do
      base = populate_map(4)

      fork =
        ephemeral(fn ->
          for _ <- 1..10, do: CAccountMap.clone(base)

          base
          |> CAccountMap.clone()
          |> CAccountMap.delete(addr(2))
        end)

      assert CAccountMap.size(fork) == 3
      assert CAccountMap.get(fork, addr(2)) == :undefined
      assert CAccountMap.get(base, addr(2)) != :undefined

      assert CAccountMap.size(base) == 4
      {_, _, storage, _} = CAccountMap.get(base, addr(2))
      assert_storage_usable(storage)
    end

    test "put replaces storage root without leaving dangling tries" do
      base = put_sample(CAccountMap.new(), 3)
      {_, _, old_storage, _} = CAccountMap.get(base, addr(3))

      new_storage = CMerkleTree.insert_items(CMerkleTree.new(), [{slot(7), val(7)}])

      base =
        CAccountMap.put(
          base,
          addr(3),
          30,
          30_000,
          new_storage,
          <<30>>
        )

      ephemeral(fn ->
        _fork = CAccountMap.clone(base)
      end)

      assert {30, 30_000, storage, <<30>>} = CAccountMap.get(base, addr(3))
      assert storage != old_storage
      assert_storage_usable(storage)
    end

    test "nested clone chain with middle resource dropped" do
      base = populate_map(3)

      c3 =
        ephemeral(fn ->
          c1 = CAccountMap.clone(base)
          c2 = CAccountMap.clone(c1)
          CAccountMap.clone(c2)
        end)

      assert entry_value(CAccountMap.get(c3, addr(2))) ==
               entry_value(CAccountMap.get(base, addr(2)))

      c3 = put_sample(c3, 50)

      assert {50, 50_000, _, <<50>>} = CAccountMap.get(c3, addr(50))
      assert CAccountMap.get(base, addr(50)) == :undefined

      ephemeral(fn ->
        _ = c3
      end)

      {_, _, storage, _} = CAccountMap.get(base, addr(2))
      assert_storage_usable(storage)
    end
  end

  describe "concurrent access while clones are collected" do
    test "parallel readers on independent clones" do
      base = populate_map(6)

      tasks =
        for _ <- 1..8 do
          Task.async(fn ->
            ephemeral(fn ->
              fork = CAccountMap.clone(base)

              for _round <- 1..25, i <- 1..6 do
                assert entry_value(CAccountMap.get(fork, addr(i))) ==
                         entry_value(CAccountMap.get(base, addr(i)))
              end
            end)

            :ok
          end)
        end

      assert Enum.all?(Task.await_many(tasks, 60_000), &(&1 == :ok))

      for i <- 1..6 do
        {_, _, storage, _} = CAccountMap.get(base, addr(i))
        assert_storage_usable(storage)
      end
    end

    test "State storage mutation on parent after many clone drops" do
      base =
        State.new()
        |> State.set_account(addr(1), sample_account(1))

      for _ <- 1..35 do
        ephemeral(fn ->
          fork = State.clone(base)
          _ = State.account(fork, addr(1))
        end)
      end

      base =
        base
        |> State.account(addr(1))
        |> Account.storage_set_value(slot(42), val(42))
        |> then(&State.set_account(base, addr(1), &1))

      assert Account.storage_value(State.account(base, addr(1)), slot(42)) == val(42)
      assert is_binary(State.hash(base))
    end
  end

  describe "list and size after resource pressure" do
    test "to_list on parent matches after fork GC and fork-only accounts" do
      base = populate_map(5)

      ephemeral(fn ->
        fork = base |> CAccountMap.clone() |> put_sample(99)

        assert map_size(Map.new(CAccountMap.to_list(base))) == 5
        assert map_size(Map.new(CAccountMap.to_list(fork))) == 6
      end)

      listed = CAccountMap.to_list(base) |> Map.new()
      assert map_size(listed) == 5
      refute Map.has_key?(listed, addr(99))

      for i <- 1..5 do
        {nonce, balance, storage, code} = Map.fetch!(listed, addr(i))
        assert {nonce, balance, code} == {i, i * 1_000, <<i>>}
        assert_storage_usable(storage)
      end
    end

    test "sequential delete of all accounts after clone siblings collected" do
      base = populate_map(5)

      ephemeral(fn ->
        for _ <- 1..15, do: CAccountMap.clone(base)
      end)

      map =
        Enum.reduce(1..5, base, fn i, acc ->
          CAccountMap.delete(acc, addr(i))
        end)

      assert CAccountMap.size(map) == 0
      assert CAccountMap.to_list(map) == []
    end
  end

  describe "clone of a locked state stays writable (block sync path)" do
    # Reproduces the startup block-sync hang: BlockProcess.cache_block/1 freezes the
    # cached parent via Chain.State.lock/1 (mt->locked = true on every storage trie),
    # and Block.create_empty/3 forks it via Chain.State.clone/1. The fork's storage
    # tries must be writable (locked = false) or the EVM's storage writes return
    # badarg and validation can never advance.
    test "storage write in a fork of a State.lock'd state succeeds and isolates parent" do
      base =
        State.new()
        |> State.set_account(addr(1), sample_account(1))

      Chain.State.lock(base)

      fork = State.clone(base)

      updated =
        fork
        |> State.account(addr(1))
        |> Account.storage_set_value(slot(42), val(42))
        |> then(&State.set_account(fork, addr(1), &1))

      assert Account.storage_value(State.account(updated, addr(1)), slot(42)) == val(42)
      assert is_binary(State.hash(updated))

      # Parent stays frozen: the fork's COW write must not leak back.
      assert Account.storage_value(State.account(base, addr(1)), slot(42)) ==
               <<0::unsigned-size(256)>>

      assert Account.storage_value(State.account(base, addr(1)), slot(1)) == val(1)
      assert is_binary(State.hash(base))
    end

    test "storage write in a fork of a locked state with many accounts" do
      base =
        Enum.reduce(1..6, State.new(), fn i, state ->
          State.set_account(state, addr(i), sample_account(i))
        end)

      Chain.State.lock(base)

      fork = State.clone(base)

      fork =
        Enum.reduce(1..6, fork, fn i, state ->
          acc =
            state
            |> State.account(addr(i))
            |> Account.storage_set_value(slot(100 + i), val(100 + i))

          State.set_account(state, addr(i), acc)
        end)

      for i <- 1..6 do
        assert Account.storage_value(State.account(fork, addr(i)), slot(100 + i)) ==
                 val(100 + i)
      end

      # Parent untouched.
      for i <- 1..6 do
        assert Account.storage_value(State.account(base, addr(i)), slot(100 + i)) ==
                 <<0::unsigned-size(256)>>
      end
    end
  end
end
