# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
#
# Focused coverage for CAccountMap / Chain.State storage_* and put_meta APIs.
defmodule CMerkleStorageMapTest do
  use ExUnit.Case, async: false

  alias Chain.State

  @moduletag timeout: 60_000

  defp addr(i), do: <<i::unsigned-size(160)>>
  defp slot(i), do: <<i::unsigned-size(256)>>
  defp val(i), do: <<i + 1::unsigned-size(256)>>

  test "storage_put_map multi-account multi-slot then get / to_list / root_hash" do
    map = CAccountMap.new()

    map =
      CAccountMap.storage_put_map(map, %{
        addr(1) => %{slot(10) => val(10), slot(11) => val(11)},
        addr(2) => %{slot(20) => val(20), slot(21) => val(21), slot(22) => val(22)}
      })

    assert CAccountMap.storage_get(map, addr(1), slot(10)) == val(10)
    assert CAccountMap.storage_get(map, addr(1), slot(11)) == val(11)
    assert CAccountMap.storage_get(map, addr(2), slot(20)) == val(20)
    assert CAccountMap.storage_get(map, addr(2), slot(22)) == val(22)
    assert CAccountMap.storage_get(map, addr(1), slot(99)) == nil

    list1 = CAccountMap.storage_to_list(map, addr(1)) |> Enum.sort()
    assert list1 == Enum.sort([{slot(10), val(10)}, {slot(11), val(11)}])

    list2 = CAccountMap.storage_to_list(map, addr(2))
    assert length(list2) == 3
    assert CAccountMap.storage_size(map, addr(1)) == 2
    assert CAccountMap.storage_size(map, addr(2)) == 3

    root1 = CAccountMap.storage_root_hash(map, addr(1))
    root2 = CAccountMap.storage_root_hash(map, addr(2))
    assert is_binary(root1) and byte_size(root1) == 32
    assert is_binary(root2) and byte_size(root2) == 32
    assert root1 != root2

    # State helpers mirror the same values.
    state = %State{accounts: map}
    assert State.storage_value(state, addr(1), slot(10)) == val(10)
    assert State.storage_size(state, addr(2)) == 3
    assert State.storage_root_hash(state, addr(1)) == root1
  end

  test "storage_put_map on frozen map raises" do
    map =
      CAccountMap.new()
      |> CAccountMap.storage_put_map(%{addr(1) => %{slot(1) => val(1)}})

    CAccountMap.lock(map)

    assert_raise ArgumentError, fn ->
      CAccountMap.storage_put_map(map, %{addr(1) => %{slot(2) => val(2)}})
    end

    assert CAccountMap.storage_get(map, addr(1), slot(1)) == val(1)
    assert CAccountMap.storage_get(map, addr(1), slot(2)) == nil
  end

  test "put_meta updates nonce without wiping storage" do
    map =
      CAccountMap.new()
      |> CAccountMap.storage_put_map(%{
        addr(1) => %{slot(5) => val(5), slot(6) => val(6)}
      })

    before_root = CAccountMap.storage_root_hash(map, addr(1))
    before_list = CAccountMap.storage_to_list(map, addr(1)) |> Enum.sort()

    map = CAccountMap.put_meta(map, addr(1), 42, 9_999, <<1, 2, 3>>)

    {nonce, balance, _storage, code} = CAccountMap.get(map, addr(1))
    assert nonce == 42
    assert balance == 9_999
    assert code == <<1, 2, 3>>

    assert CAccountMap.storage_get(map, addr(1), slot(5)) == val(5)
    assert CAccountMap.storage_get(map, addr(1), slot(6)) == val(6)
    assert CAccountMap.storage_to_list(map, addr(1)) |> Enum.sort() == before_list
    assert CAccountMap.storage_root_hash(map, addr(1)) == before_root
  end

  test "get_proofs and storage_get_proofs return terms without crashing" do
    map =
      CAccountMap.new()
      |> CAccountMap.put(addr(1), 1, 100, CMerkleTree.new(), <<>>)
      |> CAccountMap.storage_put_map(%{addr(1) => %{slot(7) => val(7)}})

    account_proof = CAccountMap.get_proofs(map, addr(1))
    assert account_proof != nil

    storage_proof = CAccountMap.storage_get_proofs(map, addr(1), slot(7))
    assert storage_proof != nil

    state = %State{accounts: map}
    assert State.get_proofs(state, addr(1)) != nil
    assert State.storage_get_proofs(state, addr(1), slot(7)) != nil
  end
end
