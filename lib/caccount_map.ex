# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CAccountMap do
  @moduledoc false
  alias Chain.Account

  @type t :: reference()
  @null <<0::unsigned-size(256)>>

  def new, do: CMerkleTree.account_map_new()

  def clone(map), do: CMerkleTree.account_map_clone(map)

  def lock(map), do: CMerkleTree.account_map_lock(map)

  def root_hash(map), do: CMerkleTree.account_map_root_hash(map)

  def state_root_hashes(map) do
    {_root, hashes} = split_roots(CMerkleTree.account_map_state_roots(map))
    hashes
  end

  def get_proofs(map, <<_::160>> = addr), do: CMerkleTree.account_map_proof(map, addr)

  def get(map, <<_::160>> = addr) do
    case CMerkleTree.account_map_get(map, addr) do
      :undefined -> :undefined
      entry -> decode_entry(entry)
    end
  end

  def get_account(map, addr) do
    case get(map, addr) do
      :undefined -> nil
      {nonce, balance, root_hash, code} -> Account.from_parts(nonce, balance, root_hash, code)
    end
  end

  def put(map, addr, nonce, balance, storage, code) do
    CMerkleTree.account_map_put(map, addr, nonce, encode_balance(balance), storage, code)
  end

  def put_meta(map, <<_::160>> = addr, nonce, balance, code) do
    put(map, addr, nonce, balance, :keep, code)
  end

  def put_account(map, <<_::160>> = addr, %Account{} = account) do
    case account.storage_root do
      nil ->
        put_meta(map, addr, account.nonce, account.balance, Account.code(account))

      storage ->
        put(map, addr, account.nonce, account.balance, storage, Account.code(account))
    end
  end

  def delete(map, <<_::160>> = addr), do: CMerkleTree.account_map_delete(map, addr)

  def size(map), do: CMerkleTree.account_map_size(map)

  def to_list(map) do
    Enum.map(CMerkleTree.account_map_to_list(map), fn {addr, entry} ->
      {addr, decode_entry(entry)}
    end)
  end

  def to_account_list(map) do
    Enum.map(to_list(map), fn {addr, {nonce, balance, root_hash, code}} ->
      {addr, Account.from_parts(nonce, balance, root_hash, code)}
    end)
  end

  @doc """
  Apply EVM-style storage updates in one NIF call.
  `updates` is `%{addr => %{slot => value}}` or a list of `{addr, [{slot, value}]}`.
  """
  def storage_put_map(map, updates) when is_map(updates) do
    list =
      Enum.map(updates, fn {addr, kvs} ->
        {addr, Map.to_list(kvs)}
      end)

    storage_put_map(map, list)
  end

  def storage_put_map(map, updates) when is_list(updates) do
    CMerkleTree.account_map_storage_put_map(map, updates)
  end

  def storage_get(map, <<_::160>> = addr, key) do
    case CMerkleTree.account_map_storage(map, addr, {:get, to_bytes32(key)}) do
      nil -> nil
      @null -> nil
      value -> value
    end
  end

  def storage_get_range(map, <<_::160>> = addr, key, count)
      when is_integer(count) and count >= 1 and count <= 256 do
    CMerkleTree.account_map_storage(map, addr, {:range, to_bytes32(key), count})
    |> Enum.map(fn {k, v} -> {k, if(v == @null, do: nil, else: v)} end)
  end

  def storage_to_list(map, <<_::160>> = addr),
    do: CMerkleTree.account_map_storage(map, addr, :list)

  def storage_size(map, <<_::160>> = addr),
    do: CMerkleTree.account_map_storage(map, addr, :size)

  def storage_root_hash(map, <<_::160>> = addr) do
    {root, _hashes} = split_roots(CMerkleTree.account_map_storage_roots(map, addr))
    root
  end

  def storage_root_hashes(map, <<_::160>> = addr) do
    {_root, hashes} = split_roots(CMerkleTree.account_map_storage_roots(map, addr))
    hashes
  end

  def storage_get_proofs(map, <<_::160>> = addr, key),
    do: CMerkleTree.account_map_proof(map, addr, to_bytes(key))

  def difference_full(map_a, map_b) do
    CMerkleTree.account_map_difference_full(map_a, map_b)
  end

  def apply_difference(map, delta), do: CMerkleTree.account_map_apply_difference(map, delta)

  def decode_storage_diff(storage_diff) do
    Map.new(storage_diff, fn {key, {val_a, val_b}} ->
      {key, {decode_storage_value(val_a), decode_storage_value(val_b)}}
    end)
  end

  defp decode_storage_value(nil), do: nil
  defp decode_storage_value(val) when is_binary(val), do: val

  def compact(map), do: CMerkleTree.account_map_compact(map)

  def uncompact_state(accounts), do: CMerkleTree.account_map_uncompact_state(accounts)

  # Third element is always a 32-byte storage root hash (never a live resource).
  defp decode_entry({nonce, balance, <<_::binary-size(32)>> = root_hash, code}) do
    {nonce, decode_balance(balance), root_hash, code}
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

  defp to_bytes32(nil), do: @null
  defp to_bytes32(int) when is_integer(int), do: <<int::unsigned-size(256)>>

  defp to_bytes32(string) when is_binary(string) and byte_size(string) < 32 do
    missing = (32 - byte_size(string)) * 8
    <<0::unsigned-size(missing), string::binary>>
  end

  defp to_bytes32(string) when is_binary(string) and byte_size(string) == 32, do: string

  defp to_bytes(string) when is_binary(string), do: string
  defp to_bytes(int) when is_integer(int), do: to_bytes32(int)

  defp split_roots(<<root::binary-size(32), hashes::binary-size(512)>>) do
    {root, decode_root_hashes(hashes)}
  end

  defp decode_root_hashes(
         <<a::binary-size(32), b::binary-size(32), c::binary-size(32), d::binary-size(32),
           e::binary-size(32), f::binary-size(32), g::binary-size(32), h::binary-size(32),
           i::binary-size(32), j::binary-size(32), k::binary-size(32), l::binary-size(32),
           m::binary-size(32), n::binary-size(32), o::binary-size(32), p::binary-size(32)>>
       ) do
    [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p]
  end
end
