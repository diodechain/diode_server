# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CAccountMapTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

  defp addr(i), do: <<i::unsigned-size(160)>>

  defp sample_account(n) do
    %Account{
      nonce: n,
      balance: n * 1_000,
      storage_root: [{<<n::unsigned-size(256)>>, <<n + 1::unsigned-size(256)>>}],
      code: <<n>>
    }
  end

  defp put_sample(map, i) do
    CAccountMap.put_account(map, addr(i), sample_account(i))
  end

  test "new/get/put roundtrip" do
    map = put_sample(CAccountMap.new(), 3)

    assert CAccountMap.size(map) == 1
    assert {3, 3000, root, <<3>>} = CAccountMap.get(map, addr(3))
    assert is_binary(root) and byte_size(root) == 32
    assert root == CAccountMap.storage_root_hash(map, addr(3))
  end

  test "delete removes account" do
    map = put_sample(CAccountMap.new(), 2) |> CAccountMap.delete(addr(2))

    assert CAccountMap.size(map) == 0
    assert CAccountMap.get(map, addr(2)) == :undefined
  end

  test "lock via NIF freezes map for fork" do
    shared = [{<<1::unsigned-size(256)>>, <<2::unsigned-size(256)>>}]

    base =
      CAccountMap.new()
      |> CAccountMap.put(addr(1), 1, 1_000, shared, <<1>>)
      |> CAccountMap.put(addr(2), 2, 2_000, shared, <<2>>)

    assert ^base = CAccountMap.lock(base)

    fork = CAccountMap.clone(base)

    fork =
      fork
      |> CAccountMap.put(addr(1), 11, 11_000, [], <<11>>)

    assert {11, 11_000, _, <<11>>} = CAccountMap.get(fork, addr(1))
    assert {1, 1_000, _, <<1>>} = CAccountMap.get(base, addr(1))
  end

  test "clone copies accounts with equal storage root hashes" do
    base = put_sample(CAccountMap.new(), 5)
    fork = CAccountMap.clone(base)

    # get/2 returns 32-byte root hashes (not live resources); content must match.
    {5, 5000, base_root, <<5>>} = CAccountMap.get(base, addr(5))
    {5, 5000, fork_root, <<5>>} = CAccountMap.get(fork, addr(5))
    assert byte_size(base_root) == 32
    assert base_root == fork_root

    assert CAccountMap.storage_root_hash(base, addr(5)) ==
             CAccountMap.storage_root_hash(fork, addr(5))

    # Fork remains writable via storage_put_map; parent root stays unchanged.
    fork =
      CAccountMap.storage_put_map(fork, %{
        addr(5) => %{<<99::unsigned-size(256)>> => <<100::unsigned-size(256)>>}
      })

    assert CAccountMap.storage_root_hash(fork, addr(5)) !=
             CAccountMap.storage_root_hash(base, addr(5))

    fork = put_sample(fork, 9)

    assert CAccountMap.get(base, addr(5)) != CAccountMap.get(fork, addr(9))
  end

  test "large balance roundtrip via 256-bit encoding" do
    balance = Bitwise.bsl(1, 200)
    map = CAccountMap.put(CAccountMap.new(), addr(2), 0, balance, nil, nil)
    assert {0, ^balance, root, ""} = CAccountMap.get(map, addr(2))
    assert is_binary(root) and byte_size(root) == 32
  end

  test "State.clone uses native account map" do
    state = State.new() |> State.set_account(addr(1), sample_account(7))

    cloned = State.clone(state)
    assert State.account(cloned, addr(1)).nonce == 7
    assert State.hash(cloned) == State.hash(state)
  end
end
