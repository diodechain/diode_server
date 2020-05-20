# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Chain.Account do
  defstruct nonce: 0, balance: 0, storage_root: nil, code: nil, root_hash: nil

  @type t :: %Chain.Account{
          nonce: non_neg_integer(),
          balance: non_neg_integer(),
          storage_root: MerkleTree.t(),
          code: binary() | nil,
          root_hash: nil
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

  @spec root(Chain.Account.t()) :: MerkleTree.t()
  def root(%Chain.Account{storage_root: nil}), do: MapMerkleTree.new()
  def root(%Chain.Account{storage_root: root}), do: root

  def put_root(%Chain.Account{} = acc, root) do
    %Chain.Account{acc | storage_root: root, root_hash: nil}
  end

  def root_hash(%Chain.Account{root_hash: nil} = acc) do
    MerkleTree.root_hash(root(acc))
  end

  def root_hash(%Chain.Account{root_hash: root_hash}) do
    root_hash
  end

  def normalize(%Chain.Account{root_hash: hash} = acc) when is_binary(hash) do
    acc
  end

  def normalize(%Chain.Account{root_hash: nil} = acc) do
    %Chain.Account{acc | root_hash: root_hash(acc)}
  end

  def storage_set_value(acc, key = <<_k::256>>, value = <<_v::256>>) do
    store = MerkleTree.insert(root(acc), key, value)
    %Chain.Account{acc | storage_root: store, root_hash: nil}
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
    case MerkleTree.get(root(acc), key) do
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

  def codehash(%Chain.Account{code: nil}) do
    Diode.hash("")
  end

  def codehash(%Chain.Account{code: code}) do
    Diode.hash(code)
  end
end
