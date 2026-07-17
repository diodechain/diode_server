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
    %Account{
      nonce: i,
      balance: i * 1_000,
      storage_root: [{slot(i), val(i)}],
      code: <<i>>,
      map_backed: false
    }
  end

  defp live_state(accounts) when is_list(accounts) do
    Enum.reduce(accounts, State.new(), fn {id, acc}, st ->
      State.set_account(st, id, acc)
    end)
  end

  defp compact_accounts(accounts) when is_list(accounts) do
    live_state(accounts) |> State.compact() |> Map.fetch!(:accounts)
  end

  defp hash_from_list_storage(%Account{storage_root: storage} = acc) when is_list(storage) do
    root =
      CAccountMap.new()
      |> CAccountMap.put(addr(0), acc.nonce, acc.balance, storage, acc.code)
      |> CAccountMap.storage_root_hash(addr(0))

    Account.hash(%{
      acc
      | root_hash: root,
        storage_root: nil,
        map_backed: true
    })
  end

  defp hash_from_compact(%Account{} = acc) do
    Account.hash(acc)
  end

  test "uncompact_state account hashes match Account.hash/1 for multi-slot storage and large code" do
    multi_slot =
      %Account{
        nonce: 11,
        balance: 5_000,
        storage_root: [
          {slot(1), val(1)},
          {slot(2), val(2)},
          {slot(10), val(10)}
        ],
        code: :binary.copy(<<0xCD>>, 1024),
        map_backed: false
      }

    compact =
      compact_accounts([
        {addr(1), multi_slot},
        {addr(2), sample_account(2)}
      ])

    {accounts, hash} = CAccountMap.uncompact_state(compact)

    elixir_hashes =
      compact
      |> Enum.map(fn {id, acc} -> {id, hash_from_compact(acc)} end)
      |> Map.new()

    nif_hashes =
      CAccountMap.to_list(accounts)
      |> Enum.map(fn {id, {nonce, balance, storage, code}} ->
        {id, Account.hash(Account.from_parts(nonce, balance, storage, code))}
      end)
      |> Map.new()

    assert nif_hashes == elixir_hashes
    assert hash == CAccountMap.root_hash(accounts)
  end

  test "uncompact_state account hashes match Account.hash/1" do
    compact =
      compact_accounts(Enum.map(1..8, fn i -> {addr(i), sample_account(i)} end))

    {accounts, hash} = CAccountMap.uncompact_state(compact)

    elixir_hashes =
      compact
      |> Enum.map(fn {id, acc} -> {id, hash_from_compact(acc)} end)
      |> Map.new()

    nif_hashes =
      CAccountMap.to_list(accounts)
      |> Enum.map(fn {id, {nonce, balance, storage, code}} ->
        {id, Account.hash(Account.from_parts(nonce, balance, storage, code))}
      end)
      |> Map.new()

    assert nif_hashes == elixir_hashes
    assert hash == CAccountMap.root_hash(accounts)
  end

  test "uncompact_state on CAccountMap resource matches Account.hash/1" do
    original =
      State.new()
      |> then(fn st ->
        Enum.reduce(1..4, st, fn i, acc ->
          State.set_account(acc, addr(i), sample_account(i))
        end)
      end)

    {accounts, hash} = CAccountMap.uncompact_state(original.accounts)

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
    assert hash == CAccountMap.root_hash(accounts)
  end

  test "uncompact_state uses compact root_hash when present" do
    compact =
      compact_accounts(Enum.map(1..4, fn i -> {addr(i), sample_account(i)} end))

    assert Enum.all?(compact, fn {_id, acc} -> Map.has_key?(acc, :root_hash) end)
    assert Enum.all?(compact, fn {_id, acc} -> Map.has_key?(acc, :code_hash) end)

    {accounts, hash} = CAccountMap.uncompact_state(compact)

    elixir_hashes =
      compact
      |> Enum.map(fn {id, acc} -> {id, hash_from_compact(acc)} end)
      |> Map.new()

    nif_hashes =
      CAccountMap.to_list(accounts)
      |> Enum.map(fn {id, {nonce, balance, storage, code}} ->
        {id, Account.hash(Account.from_parts(nonce, balance, storage, code))}
      end)
      |> Map.new()

    assert nif_hashes == elixir_hashes
    assert hash == CAccountMap.root_hash(accounts)
  end

  test "uncompact_state falls back without compact root_hash field" do
    acc = sample_account(1)

    legacy_account = %Chain.Account{
      nonce: acc.nonce,
      balance: acc.balance,
      storage_root: {MapMerkleTree, [], Map.new(acc.storage_root)},
      code: acc.code,
      map_backed: false,
      root_hash: nil
    }

    legacy_compact = %{addr(1) => legacy_account}

    {accounts, hash} = CAccountMap.uncompact_state(legacy_compact)

    {nonce, balance, storage, code} = CAccountMap.get(accounts, addr(1))

    assert Account.hash(Account.from_parts(nonce, balance, storage, code)) ==
             hash_from_list_storage(acc)

    assert hash == CAccountMap.root_hash(accounts)
    assert CAccountMap.size(accounts) == 1
  end

  test "uncompact_state falls back without compact code_hash field" do
    acc = sample_account(1)

    root =
      CAccountMap.new()
      |> CAccountMap.put(addr(0), acc.nonce, acc.balance, acc.storage_root, acc.code)
      |> CAccountMap.storage_root_hash(addr(0))

    legacy_account = %Chain.Account{
      nonce: acc.nonce,
      balance: acc.balance,
      storage_root: {MapMerkleTree, [], Map.new(acc.storage_root)},
      code: acc.code,
      map_backed: false,
      root_hash: root
    }

    legacy_compact = %{addr(1) => legacy_account}

    {accounts, hash} = CAccountMap.uncompact_state(legacy_compact)

    {nonce, balance, storage, code} = CAccountMap.get(accounts, addr(1))

    assert Account.hash(Account.from_parts(nonce, balance, storage, code)) ==
             hash_from_compact(legacy_account)

    assert hash == CAccountMap.root_hash(accounts)
    assert CAccountMap.size(accounts) == 1
  end

  test "uncompact_state rejects invalid input" do
    assert_raise ArgumentError, fn ->
      CAccountMap.uncompact_state(:not_a_map)
    end
  end

  test "State.uncompact matches original state hash" do
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
