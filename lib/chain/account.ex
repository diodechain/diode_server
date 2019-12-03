# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Chain.Account do
  defstruct nonce: 0, balance: 0, storage_root: nil, code: nil

  @type t :: %Chain.Account{
          nonce: non_neg_integer(),
          balance: non_neg_integer(),
          storage_root: MerkleTree.t(),
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

  @spec root(Chain.Account.t()) :: MnesiaMerkleTree.t()
  def root(%Chain.Account{storage_root: nil}), do: MnesiaMerkleTree.null()
  def root(%Chain.Account{storage_root: root}), do: root

  def normalize(acc) do
    if root(acc) == MnesiaMerkleTree.null() do
      %{acc | storage_root: nil}
    else
      acc
    end
  end

  def storageSetValue(acc, key = <<_k::256>>, value = <<_v::256>>) do
    store = MerkleTree.insert(root(acc), key, value)
    %Chain.Account{acc | storage_root: store}
  end

  def storageSetValue(acc, key, value) when is_integer(key) do
    storageSetValue(acc, <<key::unsigned-size(256)>>, value)
  end

  def storageSetValue(acc, key, value) when is_integer(value) do
    storageSetValue(acc, key, <<value::unsigned-size(256)>>)
  end

  @spec storageValue(Chain.Account.t(), binary() | integer()) :: binary() | nil
  def storageValue(acc, key) when is_integer(key) do
    storageValue(acc, <<key::unsigned-size(256)>>)
  end

  def storageValue(%Chain.Account{} = acc, key) when is_binary(key) do
    case MerkleTree.get(root(acc), key) do
      nil -> <<0::unsigned-size(256)>>
      bin -> bin
    end
  end

  @spec storageInteger(Chain.Account.t(), binary() | integer()) :: non_neg_integer()
  def storageInteger(acc, key) do
    case storageValue(acc, key) do
      nil -> 0
      other -> :binary.decode_unsigned(other)
    end
  end

  @spec to_rlp(Chain.Account.t()) :: [...]
  def to_rlp(%Chain.Account{} = account) do
    [
      account.nonce,
      account.balance,
      MerkleTree.root_hash(root(account)),
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
