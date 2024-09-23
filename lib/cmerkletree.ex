# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CMerkleTree do
  @on_load :load_nifs
  @null <<0::unsigned-size(256)>>

  @type t :: reference()

  def load_nifs do
    :erlang.load_nif(~c"./priv/merkletree_nif", 0)
  end

  def from_map(map) do
    import_map(new(), map)
  end

  def from_list(list) do
    insert_items(new(), list)
  end

  def list_difference(a, b) do
    a_diffmap =
      Enum.reduce(a, %{}, fn {key, value}, acc ->
        Map.put(acc, key, {value, nil})
      end)

    Enum.reduce(b, a_diffmap, fn {key, bvalue}, acc ->
      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, {nil, bvalue})

        {avalue, nil} ->
          if avalue.nonce == bvalue.nonce && avalue.balance == bvalue.balance &&
               avalue.code == bvalue.code &&
               Chain.Account.root_hash(avalue) == Chain.Account.root_hash(bvalue) do
            Map.delete(acc, key)
          else
            Map.put(acc, key, {avalue, bvalue})
          end
      end
    end)
  end

  # def difference(a, b) do
  #   list_difference(to_list(a), to_list(b))
  # end
  def difference(a, b) do
    difference_raw(a, b)
    |> Enum.map(fn
      {key, {@null, value2}} -> {key, {nil, value2}}
      {key, {value1, @null}} -> {key, {value1, nil}}
      {key, {value1, value2}} -> {key, {value1, value2}}
    end)
    |> Map.new()
  end

  def insert(tree, key, value) do
    insert_item_raw(tree, to_bytes(key), to_bytes32(value))
  end

  def insert_items(tree, items) do
    Enum.reduce(items, tree, fn {key, value}, acc ->
      insert(acc, key, value)
    end)
  end

  def get_proofs(tree, key) do
    get_proofs_raw(tree, to_bytes(key))
  end

  def insert_item(tree, {key, value}) do
    insert(tree, key, value)
  end

  def delete(tree, key) do
    insert(tree, key, @null)
  end

  def get(tree, key) do
    case get_item(tree, to_bytes32(key)) do
      nil -> nil
      {_key, @null, _hash} -> nil
      {_key, value, _hash} -> value
    end
  end

  def root_hashes(tree) do
    <<a::binary-size(32), b::binary-size(32), c::binary-size(32), d::binary-size(32),
      e::binary-size(32), f::binary-size(32), g::binary-size(32), h::binary-size(32),
      i::binary-size(32), j::binary-size(32), k::binary-size(32), l::binary-size(32),
      m::binary-size(32), n::binary-size(32), o::binary-size(32),
      p::binary-size(32)>> = root_hashes_raw(tree)

    [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p]
  end

  def new, do: error()
  def insert_item_raw(_tree, _key, _value), do: error()
  def root_hash(_tree), do: error()
  def root_hashes_raw(_tree), do: error()
  def clone(_tree), do: error()
  def size(_tree), do: error()
  def hash(_binary), do: error()
  def bucket_count(_tree), do: error()
  def get_item(_tree, _key), do: error()
  def to_list(_tree), do: error()
  def import_map(_tree, _map), do: error()
  def difference_raw(_tree, _map), do: error()
  def lock(_tree), do: error()
  def get_proofs_raw(_tree, _key), do: error()
  defp error, do: :erlang.nif_error(:nif_not_loaded)

  defp to_bytes32(nil) do
    <<0::unsigned-size(256)>>
  end

  defp to_bytes32(int) when is_integer(int) do
    <<int::unsigned-size(256)>>
  end

  defp to_bytes32(string) when byte_size(string) < 32 do
    missing = (32 - byte_size(string)) * 8
    <<0::unsigned-size(missing), string::binary>>
  end

  defp to_bytes32(string) when byte_size(string) == 32 do
    string
  end

  defp to_bytes(string) when is_binary(string), do: string
  defp to_bytes(int) when is_integer(int), do: to_bytes32(int)
end
