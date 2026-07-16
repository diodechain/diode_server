# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.Account do
  defstruct nonce: 0, balance: 0, storage_root: nil, code: nil

  @type t :: %Chain.Account{
          nonce: non_neg_integer(),
          balance: non_neg_integer(),
          storage_root: CMerkleTree.t() | nil,
          code: binary() | nil
        }

  def new(props \\ []) do
    acc = %Chain.Account{}

    Enum.reduce(props, acc, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  def code(%Chain.Account{code: nil}), do: ""
  def code(%Chain.Account{code: code}), do: code
  def nonce(%Chain.Account{nonce: nonce}), do: nonce
  def balance(%Chain.Account{balance: balance}), do: balance

  @doc """
  Live storage trie for standalone (genesis/import) accounts only.
  Map-backed accounts (`storage_root: nil` with `:root_hash`) have no live trie —
  use `Chain.State.storage_*` APIs instead.
  """
  @spec tree(Chain.Account.t()) :: CMerkleTree.t()
  def tree(%Chain.Account{storage_root: nil} = acc) do
    if map_backed?(acc) do
      raise ArgumentError,
            "map-backed account has no live storage_root; use Chain.State.storage_* APIs"
    else
      CMerkleTree.new()
    end
  end

  def tree(%Chain.Account{storage_root: root}), do: root

  @doc """
  Build an account from `CAccountMap.get/2` parts.
  When `storage` is a 32-byte root hash, the account is map-backed (`storage_root: nil`).
  When `storage` is a merkle resource (or nil), it is a standalone trie for genesis/put.
  """
  def from_parts(nonce, balance, <<root_hash::binary-size(32)>>, code) do
    %Chain.Account{
      nonce: nonce,
      balance: balance,
      storage_root: nil,
      code: if(code == "", do: nil, else: code)
    }
    |> Map.put(:root_hash, root_hash)
  end

  def from_parts(nonce, balance, storage, code) do
    %Chain.Account{
      nonce: nonce,
      balance: balance,
      storage_root: storage,
      code: if(code == "", do: nil, else: code)
    }
  end

  @deprecated "Use CMerkleTree.clone/1 on Account.tree/1 instead"
  def clone(%Chain.Account{} = acc) do
    %Chain.Account{acc | storage_root: CMerkleTree.clone(tree(acc))}
  end

  def put_tree(%Chain.Account{} = acc, root) do
    acc
    |> Map.put(:storage_root, root)
    |> Map.delete(:root_hash)
  end

  def root_hash(%Chain.Account{storage_root: nil} = acc) do
    case Map.get(acc, :root_hash) do
      <<_::binary-size(32)>> = hash -> hash
      _ -> CMerkleTree.root_hash(CMerkleTree.new())
    end
  end

  def root_hash(%Chain.Account{} = acc) do
    CMerkleTree.root_hash(tree(acc))
  end

  def uncompact(%Chain.Account{storage_root: nil} = acc) do
    %Chain.Account{acc | storage_root: CMerkleTree.new()}
  end

  def uncompact(%Chain.Account{storage_root: {MapMerkleTree, _opts, items}} = acc)
      when is_map(items) do
    storage_root = CMerkleTree.from_map(items)
    %Chain.Account{acc | storage_root: storage_root}
  end

  def uncompact(%Chain.Account{storage_root: items} = acc) when is_list(items) do
    %Chain.Account{acc | storage_root: CMerkleTree.from_list(items)}
  end

  def compact(%Chain.Account{} = acc) do
    if map_backed?(acc) do
      raise ArgumentError, "map-backed accounts are compacted via Chain.State.compact/1"
    end

    tree = tree(acc)

    if CMerkleTree.size(tree) == 0 do
      %Chain.Account{acc | storage_root: nil}
    else
      %Chain.Account{acc | storage_root: {MapMerkleTree, [], Map.new(CMerkleTree.to_list(tree))}}
    end
    |> Map.put(:root_hash, CMerkleTree.root_hash(tree))
    |> Map.put(:code_hash, codehash(acc))
  end

  def storage_set_value(%Chain.Account{} = acc, key = <<_k::256>>, value = <<_v::256>>) do
    if map_backed?(acc) do
      raise ArgumentError,
            "map-backed account storage writes go through Chain.State.storage_put_map/2"
    end

    store = CMerkleTree.insert(tree(acc), key, value)

    acc
    |> Map.put(:storage_root, store)
    |> Map.delete(:root_hash)
  end

  def storage_set_value(acc, key, value) when is_integer(key) do
    storage_set_value(acc, <<key::unsigned-size(256)>>, value)
  end

  def storage_set_value(acc, key, value) when is_integer(value) do
    storage_set_value(acc, key, <<value::unsigned-size(256)>>)
  end

  @spec storage_value(Chain.Account.t(), binary() | integer()) :: binary() | nil
  def storage_value(acc, key) when is_integer(key) do
    storage_value(acc, <<key::unsigned-size(256)>>)
  end

  def storage_value(%Chain.Account{} = acc, key) when is_binary(key) do
    if map_backed?(acc) do
      raise ArgumentError,
            "map-backed account storage reads go through Chain.State.storage_value/3"
    end

    case CMerkleTree.get(tree(acc), key) do
      nil -> <<0::unsigned-size(256)>>
      bin -> bin
    end
  end

  @spec to_rlp(Chain.Account.t()) :: [...]
  def to_rlp(%Chain.Account{} = account) do
    [
      account.nonce,
      account.balance,
      root_hash(account),
      codehash(account)
    ]
  end

  @spec hash(Chain.Account.t()) :: binary()
  def hash(%Chain.Account{} = account) do
    Diode.hash(Rlp.encode!(to_rlp(account)))
  end

  @empty_hash Diode.hash("")
  def codehash(%Chain.Account{code: nil}) do
    @empty_hash
  end

  def codehash(%Chain.Account{code: code}) do
    Diode.hash(code)
  end

  defp map_backed?(%Chain.Account{storage_root: nil} = acc), do: Map.has_key?(acc, :root_hash)
  defp map_backed?(_), do: false
end
