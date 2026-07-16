# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CMerkleCloneLazyTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

  @moduletag timeout: 120_000

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp slot(i), do: <<i::unsigned-size(256)>>

  defp val(i), do: <<i + 1::unsigned-size(256)>>

  defp force_gc(rounds \\ 3) do
    for _ <- 1..rounds, do: :erlang.garbage_collect()
  end

  defp populate(n) do
    Enum.reduce(1..n, CAccountMap.new(), fn i, map ->
      storage = CMerkleTree.insert(CMerkleTree.new(), slot(i), val(i))
      CAccountMap.put(map, addr(i), i, i * 1_000, storage, <<i>>)
    end)
  end

  test "lazy clone shares storage roots before write" do
    base = populate(50)
    fork = CAccountMap.clone_lazy(base)

    for i <- 1..50 do
      {_, _, storage_a, _} = CAccountMap.get(base, addr(i))
      {_, _, storage_b, _} = CAccountMap.get(fork, addr(i))
      assert CMerkleTree.root_hash(storage_a) == CMerkleTree.root_hash(storage_b)
    end
  end

  test "first write on lazy fork COWs storage without changing parent" do
    base = populate(5)
    fork = CAccountMap.clone_lazy(base)

    {nonce, balance, storage, code} = CAccountMap.get(fork, addr(1))
    storage = CMerkleTree.insert(storage, slot(999), val(999))
    CAccountMap.put(fork, addr(1), nonce, balance, storage, code)

    {_, _, parent_storage, _} = CAccountMap.get(base, addr(1))
    assert CMerkleTree.get(parent_storage, slot(999)) == nil
    {_, _, fork_storage, _} = CAccountMap.get(fork, addr(1))
    assert CMerkleTree.get(fork_storage, slot(999)) == val(999)
  end

  test "dropping lazy clone does not corrupt parent" do
    base = populate(10)

    fork = CAccountMap.clone_lazy(base)
    acc = CAccountMap.get_account(fork, addr(1))
    acc = Account.storage_set_value(acc, slot(42), val(42))
    _fork = CAccountMap.put_account(fork, addr(1), acc)
    force_gc()

    {_, _, storage, _} = CAccountMap.get(base, addr(1))
    assert CMerkleTree.get(storage, slot(42)) == nil
    assert is_binary(CMerkleTree.root_hash(storage))
  end

  test "clone_lazy on locked state returns badarg" do
    st =
      State.new()
      |> State.set_account(addr(1), Account.storage_set_value(Account.new(), slot(1), val(1)))

    Chain.State.lock(st)

    assert_raise ArgumentError, fn ->
      State.clone_lazy(st)
    end
  end

  test "State.clone_lazy completes for large maps" do
    base = populate(500)
    state = %Chain.State{accounts: base}

    {lazy_us, fork} = :timer.tc(fn -> State.clone_lazy(state) end)
    {eager_us, _} = :timer.tc(fn -> State.clone(state) end)

    # Today both paths fork storage wrappers; keep both under a generous bound and
    # ensure lazy stays in the same ballpark as eager (not accidentally O(n²)).
    assert lazy_us < 500_000
    assert eager_us < 500_000
    assert lazy_us < eager_us * 3
    assert is_binary(State.hash(fork))
  end
end
