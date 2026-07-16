# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CAccountMap do
  @moduledoc false
  alias Chain.Account

  @type t :: reference()

  def new, do: CMerkleTree.account_map_new()

  def clone(map), do: CMerkleTree.account_map_clone(map)

  def clone_lazy(map), do: CMerkleTree.account_map_clone_lazy(map)

  def lock(map), do: CMerkleTree.account_map_lock(map, nil)

  def root_hash(map), do: CMerkleTree.account_map_root_hash(map)

  def state_trie(map), do: CMerkleTree.account_map_state_trie(map)

  def get(map, <<_::160>> = addr) do
    case CMerkleTree.account_map_get(map, addr) do
      :undefined -> :undefined
      entry -> decode_entry(entry)
    end
  end

  def get_account(map, addr) do
    case get(map, addr) do
      :undefined -> nil
      entry -> account_from_parts(entry)
    end
  end

  def put(map, addr, nonce, balance, storage, code) do
    CMerkleTree.account_map_put(map, addr, nonce, encode_balance(balance), storage, code)
  end

  def put_account(map, <<_::160>> = addr, %Account{} = account) do
    put(map, addr, account.nonce, account.balance, Account.tree(account), Account.code(account))
  end

  def delete(map, <<_::160>> = addr), do: CMerkleTree.account_map_delete(map, addr)

  def size(map), do: CMerkleTree.account_map_size(map)

  def to_list(map) do
    Enum.map(CMerkleTree.account_map_to_list(map), fn {addr, entry} ->
      {addr, decode_entry(entry)}
    end)
  end

  def to_account_list(map) do
    Enum.map(to_list(map), fn {addr, {nonce, balance, storage, code}} ->
      {addr, Account.from_parts(nonce, balance, storage, code)}
    end)
  end

  def list_difference(map_a, map_b) do
    Map.new(CMerkleTree.account_map_list_difference_raw(map_a, map_b), fn {addr, {side_a, side_b}} ->
      {addr, {decode_account_side(side_a), decode_account_side(side_b)}}
    end)
  end

  def difference_full(map_a, map_b) do
    CMerkleTree.account_map_difference_full(map_a, map_b)
  end

  def apply_difference(map, delta) do
    case CMerkleTree.account_map_apply_difference(map, delta) do
      {:error, reason} -> {:error, reason}
      map -> map
    end
  end

  def decode_storage_diff(storage_diff) do
    Map.new(storage_diff, fn {key, {val_a, val_b}} ->
      {key, {decode_storage_value(val_a), decode_storage_value(val_b)}}
    end)
  end

  defp decode_storage_value(nil), do: nil
  defp decode_storage_value(val) when is_binary(val), do: val

  defp decode_account_side(nil), do: nil
  defp decode_account_side(entry), do: entry |> decode_entry() |> account_from_parts()

  def uncompact_state(accounts) do
    case CMerkleTree.account_map_uncompact_state(accounts) do
      {am, hash} -> {am, hash}
    end
  end

  defp decode_entry({nonce, balance, storage, code}) do
    {nonce, decode_balance(balance), storage, code}
  end

  defp account_from_parts({nonce, balance, storage, code}) do
    Account.from_parts(nonce, balance, storage, code)
  end

  defp encode_balance(balance) when is_integer(balance) and balance >= 0 do
    if balance <= 0xFFFFFFFFFFFFFFFF do
      balance
    else
      <<balance::unsigned-size(256)>>
    end
  end

  defp decode_balance(balance) when is_integer(balance), do: balance

  defp decode_balance(balance) when is_binary(balance) do
    :binary.decode_unsigned(balance)
  end
end
