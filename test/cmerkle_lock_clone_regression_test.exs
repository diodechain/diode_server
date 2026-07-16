# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
#
# Regressions for lock/clone/storage_put_map after clone_lazy removal:
# 1) Cached/locked peak must use State.clone/1 for speculative forks.
# 2) State.lock freezes the account map (storage_put_map / put / delete raise).
# 3) Shared-storage lock must not deadlock.
# 4) difference_full is the sole NIF diff path.
# 5) State.storage_put_map works unlocked and raises on locked maps.
# 6) CAccountMap.get/2 returns a 32-byte storage root hash (never a live trie).
defmodule CMerkleLockCloneRegressionTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

  @moduletag timeout: 120_000

  defp addr(i), do: <<i::unsigned-size(160)>>
  defp slot(i), do: <<i::unsigned-size(256)>>
  defp val(i), do: <<i + 1::unsigned-size(256)>>

  defp sample_account(i) do
    Account.new()
    |> Account.storage_set_value(slot(i), val(i))
    |> Map.put(:nonce, i)
    |> Map.put(:balance, i * 1_000)
    |> Map.put(:code, <<i>>)
  end

  defp locked_peak_like_state(n \\ 3) do
    state =
      Enum.reduce(1..n, State.new(), fn i, st ->
        State.set_account(st, addr(i), sample_account(i))
      end)

    # BlockProcess.cache_block/1 locks the cached state before RPC/Edge/Shell read it.
    State.lock(state)
    state
  end

  describe "cached peak speculative path (RPC/EdgeV2/Shell regression)" do
    test "lock then clone/1 succeeds and isolates parent" do
      peak = locked_peak_like_state()

      fork = State.clone(peak)

      updated =
        State.storage_put_map(fork, %{
          addr(1) => %{slot(999) => val(999)}
        })

      assert State.storage_value(updated, addr(1), slot(999)) == val(999)

      assert State.storage_value(peak, addr(1), slot(999)) ==
               <<0::unsigned-size(256)>>
    end

    test "set_account and put on locked peak raise without mutating parent" do
      peak = locked_peak_like_state(1)
      before_hash = State.hash(peak)
      before_slot = State.storage_value(peak, addr(1), slot(1))

      acc =
        State.account(peak, addr(1))
        |> Map.put(:nonce, 99)

      assert_raise ArgumentError, fn ->
        State.set_account(peak, addr(1), acc)
      end

      assert_raise ArgumentError, fn ->
        CAccountMap.put(
          peak.accounts,
          addr(1),
          99,
          1,
          CMerkleTree.new(),
          <<>>
        )
      end

      assert_raise ArgumentError, fn ->
        CAccountMap.delete(peak.accounts, addr(1))
      end

      assert State.hash(peak) == before_hash
      assert State.storage_value(peak, addr(1), slot(1)) == before_slot
    end

    test "storage_put_map on unlocked works; on locked raises" do
      unlocked =
        State.new()
        |> State.set_account(addr(1), sample_account(1))

      updated =
        State.storage_put_map(unlocked, %{
          addr(1) => %{slot(42) => val(42)}
        })

      assert CAccountMap.storage_get(updated.accounts, addr(1), slot(42)) == val(42)
      assert CAccountMap.storage_get(updated.accounts, addr(1), slot(1)) == val(1)

      peak = State.lock(unlocked)

      assert_raise ArgumentError, fn ->
        State.storage_put_map(peak, %{addr(1) => %{slot(43) => val(43)}})
      end

      assert CAccountMap.storage_get(peak.accounts, addr(1), slot(43)) == nil
      assert CAccountMap.storage_get(peak.accounts, addr(1), slot(1)) == val(1)
    end
  end

  describe "lock storage immutability" do
    test "get returns 32-byte root hash; storage_put_map on locked raises" do
      peak = locked_peak_like_state(1)
      {_n, _b, root, _c} = CAccountMap.get(peak.accounts, addr(1))
      assert is_binary(root) and byte_size(root) == 32
      assert root == CAccountMap.storage_root_hash(peak.accounts, addr(1))
      before = CAccountMap.storage_get(peak.accounts, addr(1), slot(1))

      assert_raise ArgumentError, fn ->
        CAccountMap.storage_put_map(peak.accounts, %{addr(1) => %{slot(42) => val(42)}})
      end

      assert CAccountMap.storage_get(peak.accounts, addr(1), slot(1)) == before
      assert CAccountMap.storage_get(peak.accounts, addr(1), slot(42)) == nil
    end

    test "put and storage_put_map on frozen map raise; state_trie remains readable" do
      peak = locked_peak_like_state(1)
      trie = State.tree(peak)
      before = CMerkleTree.root_hash(trie)

      assert_raise ArgumentError, fn ->
        State.storage_put_map(peak, %{addr(1) => %{slot(9) => val(9)}})
      end

      assert_raise ArgumentError, fn ->
        CAccountMap.put(peak.accounts, addr(9), 0, 0, CMerkleTree.new(), <<>>)
      end

      # Lock is frozen-only on the account map; State.tree still returns a live
      # resource for reads. Root hash of the state trie must stay unchanged.
      assert CMerkleTree.root_hash(trie) == before
      assert CMerkleTree.root_hash(State.tree(peak)) == before
    end

    test "apply_difference on locked map raises; clone then apply succeeds" do
      prev =
        State.new()
        |> State.set_account(addr(1), sample_account(1))

      next =
        prev
        |> State.clone()
        |> State.storage_put_map(%{addr(1) => %{slot(7) => val(7)}})

      delta = State.difference(prev, next)

      State.lock(prev)

      assert_raise ArgumentError, fn ->
        State.apply_difference(prev, delta)
      end

      restored =
        prev
        |> State.clone()
        |> State.apply_difference(delta)

      assert State.storage_value(restored, addr(1), slot(7)) == val(7)

      assert State.storage_value(prev, addr(1), slot(7)) ==
               <<0::unsigned-size(256)>>
    end
  end

  describe "shared storage lock (apply_canonical_lock regression)" do
    test "lock with many accounts sharing one storage completes and stays forkable" do
      shared =
        Enum.reduce(1..8, CMerkleTree.new(), fn i, tree ->
          CMerkleTree.insert(tree, slot(i), val(i))
        end)

      accounts =
        Enum.reduce(1..40, CAccountMap.new(), fn i, map ->
          CAccountMap.put(map, addr(i), i, i * 100, shared, <<i>>)
        end)

      base = %State{State.new() | accounts: accounts}

      {lock_us, _} = :timer.tc(fn -> State.lock(base) end)
      assert lock_us < 2_000_000, "shared-storage lock hung or was too slow: #{lock_us}µs"

      {clone_us, fork} = :timer.tc(fn -> State.clone(base) end)
      assert clone_us < 2_000_000

      updated =
        State.storage_put_map(fork, %{
          addr(1) => %{slot(999) => val(999)}
        })

      assert State.storage_value(updated, addr(1), slot(999)) == val(999)

      assert State.storage_value(base, addr(1), slot(999)) ==
               <<0::unsigned-size(256)>>

      # Sibling account still sees original shared slots on the frozen parent.
      assert State.storage_value(base, addr(2), slot(1)) == val(1)
    end

    test "concurrent locks on distinct maps that share storage roots do not hang" do
      # Same root hash via independent trees (one resource must not be kept by many
      # AccountMaps). Concurrent lock+clone must complete without hanging.
      maps =
        for i <- 1..8 do
          storage =
            CMerkleTree.insert_items(CMerkleTree.new(), [
              {slot(1), val(1)},
              {slot(2), val(2)}
            ])

          CAccountMap.new()
          |> CAccountMap.put(addr(i), i, i * 10, storage, <<i>>)
          |> CAccountMap.put(addr(100 + i), i, i * 10, storage, <<i>>)
        end

      forks =
        maps
        |> Task.async_stream(
          fn map ->
            CAccountMap.lock(map)
            CAccountMap.clone(map)
          end,
          max_concurrency: 8,
          timeout: 5_000,
          ordered: true
        )
        |> Enum.map(fn {:ok, fork} -> fork end)

      assert length(forks) == 8

      Enum.each(forks, fn fork ->
        assert CAccountMap.size(fork) == 2
      end)
    end
  end

  describe "difference_full sole NIF path" do
    test "State.difference on locked peak vs mutated clone round-trips via clone+apply" do
      peak = locked_peak_like_state(4)

      next =
        peak
        |> State.clone()
        |> State.storage_put_map(%{addr(2) => %{slot(50) => val(50)}})
        |> then(fn st ->
          State.set_account(st, addr(9), sample_account(9))
        end)

      delta = State.difference(peak, next)
      assert is_list(delta)
      assert delta != []

      full_ids =
        CAccountMap.difference_full(peak.accounts, next.accounts)
        |> Enum.map(fn {id, _, _, _} -> id end)
        |> Enum.sort()

      assert full_ids == Enum.sort([addr(2), addr(9)])

      restored =
        peak
        |> State.clone()
        |> State.apply_difference(delta)
        |> State.normalize()

      assert State.hash(restored) == State.hash(State.normalize(next))
    end
  end
end
