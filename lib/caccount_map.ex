# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CAccountMap do
  @moduledoc false
  alias Chain.Account

  @type t :: reference()

  def new, do: CMerkleTree.account_map_new()

  def clone(map), do: CMerkleTree.account_map_clone(map)

  def get(map, <<_::160>> = addr) do
    case CMerkleTree.account_map_get(map, addr) do
      :undefined -> :undefined
      entry -> decode_entry(entry)
    end
  end

  def get_account(map, addr) do
    case get(map, addr) do
      :undefined ->
        nil

      {nonce, balance, storage, code} ->
        Account.from_parts(nonce, balance, storage, code)
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

  defp decode_entry({nonce, balance, storage, code}) do
    {nonce, decode_balance(balance), storage, code}
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
