# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
#
# Regression and performance tests for Chain.State.uncompact/1 on compact DB states.
defmodule ChainStateUncompactTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

  @moduletag timeout: 300_000
  @account_count 14_609

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp slot(i), do: <<i::unsigned-size(256)>>

  defp val(i), do: <<i + 1::unsigned-size(256)>>

  defp sample_account(i) do
    tree =
      CMerkleTree.insert_items(CMerkleTree.new(), [
        {slot(i), val(i)}
      ])

    %Account{nonce: i, balance: i * 1_000, storage_root: tree, code: <<i>>}
  end

  defp compact_accounts_map(n_accounts) do
    for i <- 1..n_accounts, into: %{} do
      {addr(i), sample_account(i) |> Account.compact()}
    end
  end

  defp compact_state(n_accounts) do
    %State{accounts: compact_accounts_map(n_accounts)}
  end

  defp live_state(n_accounts) do
    State.new()
    |> then(fn st ->
      Enum.reduce(1..n_accounts, st, fn i, acc ->
        State.set_account(acc, addr(i), sample_account(i))
      end)
    end)
  end

  describe "uncompact correctness" do
    test "compact map round-trips through uncompact with stable state hash" do
      original = live_state(32)
      compact = State.compact(original)
      assert is_map(compact.accounts)

      restored = State.uncompact(compact)
      assert State.hash(restored) == State.hash(original)
      assert CAccountMap.size(restored.accounts) == 32

      for i <- 1..32 do
        acc = State.account(restored, addr(i))
        assert acc.nonce == i
        assert Account.storage_value(acc, slot(i)) == val(i)
      end
    end

    test "empty compact map" do
      restored = State.uncompact(%State{accounts: %{}})
      assert CAccountMap.size(restored.accounts) == 0
      assert restored.store != nil
      assert State.hash(restored) == CMerkleTree.root_hash(CMerkleTree.new())
    end

    test "empty CAccountMap resource" do
      restored = State.uncompact(%State{accounts: CAccountMap.new()})
      assert CAccountMap.size(restored.accounts) == 0
      assert restored.store != nil
      assert State.hash(restored) == CMerkleTree.root_hash(CMerkleTree.new())
    end

    test "live CAccountMap resource rebuilds state trie" do
      original = live_state(8)
      hash = State.hash(original)

      restored = State.uncompact(original)
      assert State.hash(restored) == hash
      assert CAccountMap.size(restored.accounts) == 8
      assert restored.store != nil
      refute restored.accounts === original.accounts
    end

    test "idempotent on already uncompacted CAccountMap state" do
      original = live_state(4)
      once = State.uncompact(State.compact(original))
      twice = State.uncompact(once)

      assert State.hash(twice) == State.hash(once)
      assert CAccountMap.size(twice.accounts) == 4
    end

    test "multi-slot map storage survives uncompact and matches live state hash" do
      multi_slot =
        %Account{
          nonce: 3,
          balance: 99,
          storage_root:
            CMerkleTree.insert_items(CMerkleTree.new(), [
              {slot(1), val(1)},
              {slot(2), val(2)},
              {slot(3), val(3)}
            ]),
          code: :binary.copy(<<0xAB>>, 512)
        }

      empty_code =
        %Account{nonce: 0, balance: 0, storage_root: nil, code: nil}

      original =
        State.new()
        |> State.set_account(addr(1), multi_slot)
        |> State.set_account(addr(2), empty_code)
        |> State.set_account(addr(3), sample_account(7))

      compact = State.compact(original)
      restored = State.uncompact(compact)

      assert State.hash(restored) == State.hash(original)
      assert CAccountMap.size(restored.accounts) == 3

      acc1 = State.account(restored, addr(1))
      assert acc1.nonce == 3
      assert acc1.balance == 99
      assert acc1.code == :binary.copy(<<0xAB>>, 512)
      assert Account.storage_value(acc1, slot(1)) == val(1)
      assert Account.storage_value(acc1, slot(2)) == val(2)
      assert Account.storage_value(acc1, slot(3)) == val(3)

      acc2 = State.account(restored, addr(2))
      assert acc2.code == nil
      assert CMerkleTree.size(Account.tree(acc2)) == 0
    end

    test "compact account edge cases: nil storage, nil code, large balance, list storage" do
      list_storage_account = %Account{
        nonce: 0,
        balance: 100_000_000_000_000_000_000_000_000,
        storage_root: [{slot(1), val(1)}],
        code: nil
      }

      compact =
        %{
          addr(1) => list_storage_account,
          addr(2) =>
            %Account{
              nonce: 7,
              balance: 42,
              storage_root: nil,
              code: nil
            }
            |> Account.compact()
        }

      restored = State.uncompact(%State{accounts: compact})
      assert CAccountMap.size(restored.accounts) == 2

      acc1 = State.account(restored, addr(1))
      assert acc1.balance == 100_000_000_000_000_000_000_000_000
      assert Account.storage_value(acc1, slot(1)) == val(1)

      acc2 = State.account(restored, addr(2))
      assert acc2.nonce == 7
      assert acc2.balance == 42
      assert acc2.code == nil
      assert CMerkleTree.size(Account.tree(acc2)) == 0
    end

    test "lazy storage materializes on CAccountMap.get without State.account" do
      multi_slot =
        %Account{
          nonce: 5,
          balance: 1_000,
          storage_root:
            CMerkleTree.insert_items(CMerkleTree.new(), [
              {slot(1), val(1)},
              {slot(2), val(2)}
            ]),
          code: <<5>>
        }

      compact = %{addr(1) => Account.compact(multi_slot)}
      {accounts, _store, _hash} = CAccountMap.uncompact_state(compact)

      {5, 1_000, storage, <<5>>} = CAccountMap.get(accounts, addr(1))

      assert CMerkleTree.get(storage, slot(1)) == val(1)
      assert CMerkleTree.get(storage, slot(2)) == val(2)
    end

    test "clone preserves lazy storage until materialized" do
      original =
        live_state(4)
        |> State.compact()
        |> State.uncompact()

      cloned = %{original | accounts: CAccountMap.clone(original.accounts)}
      assert State.hash(cloned) == State.hash(original)

      for i <- 1..4 do
        acc = State.account(cloned, addr(i))
        assert Account.storage_value(acc, slot(i)) == val(i)
      end
    end
  end

  describe "lazy storage lifecycle risks" do
    defp force_gc(rounds \\ 3) do
      for _ <- 1..rounds, do: :erlang.garbage_collect()
    end

    defp uncompact_from_compact(n_accounts) do
      compact_state(n_accounts)
      |> then(fn st -> elem(CAccountMap.uncompact_state(st.accounts), 0) end)
    end

    test "Account.compact stores code_hash matching Account.codehash/1" do
      acc = sample_account(3) |> Map.put(:code, :binary.copy(<<0xEE>>, 256))
      compact = Account.compact(acc)

      assert compact.code_hash == Account.codehash(acc)
      assert compact.root_hash == Account.root_hash(acc)
    end

    test "put overwrites lazy account without prior get" do
      compact = %{addr(1) => sample_account(1) |> Account.compact()}
      {accounts, _, _} = CAccountMap.uncompact_state(compact)

      new_storage =
        CMerkleTree.insert_items(CMerkleTree.new(), [
          {slot(99), val(99)}
        ])

      accounts =
        CAccountMap.put(accounts, addr(1), 9, 9_000, new_storage, <<9>>)

      assert {9, 9_000, storage, <<9>>} = CAccountMap.get(accounts, addr(1))
      assert CMerkleTree.get(storage, slot(99)) == val(99)
      refute CMerkleTree.get(storage, slot(1)) == val(1)
    end

    test "to_list materializes lazy storage for every account" do
      accounts = uncompact_from_compact(4)

      listed =
        accounts
        |> CAccountMap.to_list()
        |> Map.new()

      assert map_size(listed) == 4

      for i <- 1..4 do
        {_nonce, _balance, storage, code} = Map.fetch!(listed, addr(i))
        assert code == <<i>>
        assert CMerkleTree.get(storage, slot(i)) == val(i)
        assert CMerkleTree.root_hash(storage) == Account.root_hash(sample_account(i))
      end
    end

    test "delete removes lazy account" do
      accounts = uncompact_from_compact(3)
      accounts = CAccountMap.delete(accounts, addr(2))

      assert CAccountMap.size(accounts) == 2
      assert CAccountMap.get(accounts, addr(2)) == :undefined
      assert CAccountMap.get(accounts, addr(1)) != :undefined
    end

    test "clone GC after lazy uncompact leaves parent storage readable" do
      restored = live_state(6) |> State.compact() |> State.uncompact()

      _fork = CAccountMap.clone(restored.accounts)
      assert CAccountMap.size(_fork) == 6
      _fork = nil
      force_gc()

      for i <- 1..6 do
        assert Account.storage_value(State.account(restored, addr(i)), slot(i)) == val(i)
      end
    end

    test "fork put on lazy map isolates parent account data" do
      compact = compact_accounts_map(3)
      {accounts, _, _} = CAccountMap.uncompact_state(compact)

      new_storage = CMerkleTree.insert_items(CMerkleTree.new(), [{slot(50), val(50)}])

      fork =
        accounts
        |> CAccountMap.clone()
        |> CAccountMap.put(addr(1), 99, 99_000, new_storage, <<99>>)

      assert {1, 1_000, _, <<1>>} = CAccountMap.get(accounts, addr(1))
      assert {99, 99_000, _, <<99>>} = CAccountMap.get(fork, addr(1))
    end

    test "locked state clone stays writable after lazy uncompact (block sync path)" do
      restored = live_state(4) |> State.compact() |> State.uncompact()
      Chain.State.lock(restored)

      fork = State.clone(restored)

      fork =
        Enum.reduce(1..4, fork, fn i, state ->
          acc =
            state
            |> State.account(addr(i))
            |> Account.storage_set_value(slot(100 + i), val(100 + i))

          State.set_account(state, addr(i), acc)
        end)

      for i <- 1..4 do
        assert Account.storage_value(State.account(fork, addr(i)), slot(100 + i)) ==
                 val(100 + i)

        assert Account.storage_value(State.account(restored, addr(i)), slot(100 + i)) ==
                 <<0::unsigned-size(256)>>
      end
    end
  end

  describe "uncompact performance" do
    @fixture_path Path.join(System.tmp_dir!(), "diode_uncompact_perf_#{@account_count}.bin")

    @tag :callgrind
    @tag :slow
    test "valgrind profile target: NIF uncompact only at production scale" do
      state =
        if File.exists?(@fixture_path) do
          @fixture_path |> File.read!() |> :erlang.binary_to_term()
        else
          compact_state(@account_count)
          |> tap(fn s -> File.write!(@fixture_path, :erlang.term_to_binary(s)) end)
        end

      restored = State.uncompact(state)
      assert CAccountMap.size(restored.accounts) == @account_count
      assert restored.store != nil
    end

    @tag :slow
    test "profiles uncompact at ~14k compact accounts (production scale)" do
      state = compact_state(@account_count)
      assert map_size(state.accounts) == @account_count

      {reduce_us, _accounts} =
        :timer.tc(fn ->
          Enum.reduce(state.accounts, CAccountMap.new(), fn {id, acc}, accounts ->
            CAccountMap.put_account(accounts, id, Account.uncompact(acc))
          end)
        end)

      {tree_us, _tree} =
        :timer.tc(fn ->
          state.accounts
          |> Enum.map(fn {id, acc} -> {id, Account.hash(Account.uncompact(acc))} end)
          |> Map.new()
          |> CMerkleTree.from_map()
        end)

      {full_us, restored} = :timer.tc(fn -> State.uncompact(state) end)

      assert CAccountMap.size(restored.accounts) == @account_count
      assert is_binary(State.hash(restored))
      assert restored.store != nil

      reduce_ms = Float.round(reduce_us / 1000, 1)
      tree_ms = Float.round(tree_us / 1000, 1)
      full_ms = Float.round(full_us / 1000, 1)

      IO.puts("""
      State.uncompact performance (@account_count=#{@account_count}):
        reduce+put loop: #{reduce_ms} ms
        tree(from_map) estimate: #{tree_ms} ms
        full uncompact: #{full_ms} ms
      """)

      assert full_us < 150_000,
             "full uncompact exceeded 150ms ceiling (#{full_ms} ms)"
    end
  end
end
