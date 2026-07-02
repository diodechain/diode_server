# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CAccountMapTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp sample_account(n) do
    tree =
      CMerkleTree.insert_items(CMerkleTree.new(), [
        {<<n::unsigned-size(256)>>, <<n + 1::unsigned-size(256)>>}
      ])

    %Account{nonce: n, balance: n * 1_000, storage_root: tree, code: <<n>>}
  end

  defp put_sample(map, i) do
    CAccountMap.put_account(map, addr(i), sample_account(i))
  end

  test "new/get/put roundtrip" do
    map = put_sample(CAccountMap.new(), 3)

    assert CAccountMap.size(map) == 1
    assert {3, 3000, storage, <<3>>} = CAccountMap.get(map, addr(3))
    assert CMerkleTree.root_hash(storage) == Account.root_hash(sample_account(3))
  end

  test "delete removes account" do
    map = put_sample(CAccountMap.new(), 2) |> CAccountMap.delete(addr(2))

    assert CAccountMap.size(map) == 0
    assert CAccountMap.get(map, addr(2)) == :undefined
  end

  test "clone shares map and storage until mutation" do
    base = put_sample(CAccountMap.new(), 5)
    fork = CAccountMap.clone(base)

    assert CAccountMap.get(fork, addr(5)) == CAccountMap.get(base, addr(5))

    fork = put_sample(fork, 9)

    assert CAccountMap.get(base, addr(5)) != CAccountMap.get(fork, addr(9))
  end

  test "large balance roundtrip via 256-bit encoding" do
    balance = Bitwise.bsl(1, 200)
    storage = CMerkleTree.new()
    map = CAccountMap.put(CAccountMap.new(), addr(2), 0, balance, storage, nil)
    assert {0, ^balance, _, ""} = CAccountMap.get(map, addr(2))
  end

  test "State.clone uses native account map" do
    state = State.new() |> State.set_account(addr(1), sample_account(7))

    cloned = State.clone(state)
    assert State.account(cloned, addr(1)).nonce == 7
    assert State.hash(cloned) == State.hash(state)
  end
end
