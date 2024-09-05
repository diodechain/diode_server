# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.Account do
  defstruct nonce: 0, balance: 0, storage_root: nil, code: nil

  @type t :: %Chain.Account{
          nonce: non_neg_integer(),
          balance: non_neg_integer(),
          storage_root: CMerkleTree.t(),
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

  @spec tree(Chain.Account.t()) :: CMerkleTree.t()
  def tree(%Chain.Account{storage_root: nil}), do: CMerkleTree.new()
  def tree(%Chain.Account{storage_root: root}), do: root

  def clone(%Chain.Account{} = acc) do
    %Chain.Account{acc | storage_root: CMerkleTree.clone(tree(acc))}
  end

  def put_tree(%Chain.Account{} = acc, root) do
    %Chain.Account{acc | storage_root: root}
  end

  def root_hash(%Chain.Account{} = acc) do
    CMerkleTree.root_hash(tree(acc))
  end

  def uncompact(%Chain.Account{storage_root: nil} = acc) do
    %Chain.Account{acc | storage_root: CMerkleTree.new()}
  end

  def uncompact(%Chain.Account{storage_root: {MapMerkleTree, _opts, items}} = acc)
      when is_map(items) do
    # old_root = Map.get(acc, :root_hash)
    storage_root = CMerkleTree.from_map(items)

    # if old_root != CMerkleTree.root_hash(storage_root) do
    #   IO.inspect({old_root, CMerkleTree.root_hash(storage_root)}, label: "root_hash mismatch")
    # end

    %Chain.Account{acc | storage_root: storage_root}
  end

  def uncompact(%Chain.Account{storage_root: items} = acc) when is_list(items) do
    %Chain.Account{acc | storage_root: CMerkleTree.from_list(items)}
  end

  def compact(%Chain.Account{} = acc) do
    tree = tree(acc)

    if CMerkleTree.size(tree) == 0 do
      %Chain.Account{acc | storage_root: nil}
    else
      %Chain.Account{acc | storage_root: {MapMerkleTree, [], Map.new(CMerkleTree.to_list(tree))}}
    end
    |> Map.put(:root_hash, CMerkleTree.root_hash(tree))
  end

  def storage_set_value(acc, key = <<_k::256>>, value = <<_v::256>>) do
    store = CMerkleTree.insert(tree(acc), key, value)
    %Chain.Account{acc | storage_root: store}
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
end
