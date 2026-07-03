# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
#
# Golden tests: C++ account hash / combined uncompact_state matches Elixir Account.hash.
defmodule ChainAccountHashNifTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

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

  test "uncompact_state account hashes match Account.hash/1 for multi-slot storage and large code" do
    multi_slot =
      %Account{
        nonce: 11,
        balance: 5_000,
        storage_root:
          CMerkleTree.insert_items(CMerkleTree.new(), [
            {slot(1), val(1)},
            {slot(2), val(2)},
            {slot(10), val(10)}
          ]),
        code: :binary.copy(<<0xCD>>, 1024)
      }

    compact =
      %{
        addr(1) => multi_slot |> Account.compact(),
        addr(2) => sample_account(2) |> Account.compact()
      }

    {accounts, store, hash} = CAccountMap.uncompact_state(compact)

    elixir_hashes =
      compact
      |> Enum.map(fn {id, acc} -> {id, Account.hash(Account.uncompact(acc))} end)
      |> Map.new()

    nif_hashes =
      CAccountMap.to_list(accounts)
      |> Enum.map(fn {id, {nonce, balance, storage, code}} ->
        {id, Account.hash(Account.from_parts(nonce, balance, storage, code))}
      end)
      |> Map.new()

    assert nif_hashes == elixir_hashes
    assert hash == CMerkleTree.root_hash(store)
  end

  test "uncompact_state account hashes match Account.hash/1" do
    compact =
      for i <- 1..8, into: %{} do
        {addr(i), sample_account(i) |> Account.compact()}
      end

    {accounts, store, hash} = CAccountMap.uncompact_state(compact)

    elixir_hashes =
      compact
      |> Enum.map(fn {id, acc} -> {id, Account.hash(Account.uncompact(acc))} end)
      |> Map.new()

    nif_hashes =
      CAccountMap.to_list(accounts)
      |> Enum.map(fn {id, {nonce, balance, storage, code}} ->
        {id, Account.hash(Account.from_parts(nonce, balance, storage, code))}
      end)
      |> Map.new()

    assert nif_hashes == elixir_hashes

    elixir_root =
      elixir_hashes
      |> CMerkleTree.from_map()
      |> CMerkleTree.root_hash()

    assert hash == elixir_root
    assert CMerkleTree.root_hash(store) == elixir_root
  end

  test "uncompact_state on CAccountMap resource matches Account.hash/1" do
    original =
      State.new()
      |> then(fn st ->
        Enum.reduce(1..4, st, fn i, acc ->
          State.set_account(acc, addr(i), sample_account(i))
        end)
      end)

    {accounts, store, hash} = CAccountMap.uncompact_state(original.accounts)

    elixir_hashes =
      original.accounts
      |> CAccountMap.to_account_list()
      |> Enum.map(fn {id, acc} -> {id, Account.hash(acc)} end)
      |> Map.new()

    nif_hashes =
      CAccountMap.to_list(accounts)
      |> Enum.map(fn {id, {nonce, balance, storage, code}} ->
        {id, Account.hash(Account.from_parts(nonce, balance, storage, code))}
      end)
      |> Map.new()

    assert nif_hashes == elixir_hashes
    assert hash == CMerkleTree.root_hash(store)
  end

  test "uncompact_state uses compact root_hash when present" do
    compact =
      for i <- 1..4, into: %{} do
        {addr(i), sample_account(i) |> Account.compact()}
      end

    assert Enum.all?(compact, fn {_id, acc} -> Map.has_key?(acc, :root_hash) end)
    assert Enum.all?(compact, fn {_id, acc} -> Map.has_key?(acc, :code_hash) end)

    {accounts, store, hash} = CAccountMap.uncompact_state(compact)

    elixir_hashes =
      compact
      |> Enum.map(fn {id, acc} -> {id, Account.hash(Account.uncompact(acc))} end)
      |> Map.new()

    nif_hashes =
      CAccountMap.to_list(accounts)
      |> Enum.map(fn {id, {nonce, balance, storage, code}} ->
        {id, Account.hash(Account.from_parts(nonce, balance, storage, code))}
      end)
      |> Map.new()

    assert nif_hashes == elixir_hashes
    assert hash == CMerkleTree.root_hash(store)
  end

  test "uncompact_state falls back without compact root_hash field" do
    acc = sample_account(1)
    tree = Account.tree(acc)

    legacy_account = %Chain.Account{
      nonce: acc.nonce,
      balance: acc.balance,
      storage_root: {MapMerkleTree, [], Map.new(CMerkleTree.to_list(tree))},
      code: acc.code
    }

    legacy_compact = %{addr(1) => legacy_account}

    {accounts, store, hash} = CAccountMap.uncompact_state(legacy_compact)

    expected_hash =
      legacy_account
      |> Account.uncompact()
      |> Account.hash()

    expected_root =
      %{addr(1) => expected_hash}
      |> CMerkleTree.from_map()
      |> CMerkleTree.root_hash()

    assert hash == expected_root
    assert CMerkleTree.root_hash(store) == expected_root
    assert CAccountMap.size(accounts) == 1
  end

  test "uncompact_state falls back without compact code_hash field" do
    acc = sample_account(1)
    tree = Account.tree(acc)

    legacy_account =
      acc
      |> Map.from_struct()
      |> Map.put(:storage_root, {MapMerkleTree, [], Map.new(CMerkleTree.to_list(tree))})
      |> Map.put(:root_hash, Account.root_hash(acc))
      |> Map.delete(:code_hash)
      |> then(&struct(Chain.Account, &1))

    legacy_compact = %{addr(1) => legacy_account}

    {accounts, store, hash} = CAccountMap.uncompact_state(legacy_compact)

    expected_hash =
      legacy_account
      |> Account.uncompact()
      |> Account.hash()

    expected_root =
      %{addr(1) => expected_hash}
      |> CMerkleTree.from_map()
      |> CMerkleTree.root_hash()

    assert hash == expected_root
    assert CMerkleTree.root_hash(store) == expected_root
    assert CAccountMap.size(accounts) == 1
  end

  test "uncompact_state rejects invalid input" do
    assert_raise ArgumentError, fn ->
      CAccountMap.uncompact_state(:not_a_map)
    end
  end

  test "State.uncompact matches Elixir tree/1 hash" do
    original =
      State.new()
      |> then(fn st ->
        Enum.reduce(1..16, st, fn i, acc ->
          State.set_account(acc, addr(i), sample_account(i))
        end)
      end)

    compact = State.compact(original)
    restored = State.uncompact(compact)

    assert State.hash(restored) == State.hash(original)
    assert is_map(compact.accounts)
  end
end
