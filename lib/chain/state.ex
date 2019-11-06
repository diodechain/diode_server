# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Chain.State do
  import Wallet
  defstruct store: MerkleTree.new(), map: %{}

  def new() do
    %Chain.State{store: MerkleTree.new()}
  end

  def hash(%Chain.State{store: tree}) do
    MerkleTree.root_hash(tree)
  end

  def accounts(%Chain.State{store: store, map: map}) do
    MerkleTree.to_list(store)
    |> Enum.map(fn {key, value} -> {key, Map.get(map, value)} end)
    |> Map.new()
  end

  @spec account(Chain.State.t(), <<_::160>>) :: Chain.Account.t() | nil
  def account(%Chain.State{store: store, map: map}, id = <<_::160>>) do
    Map.get(map, MerkleTree.get(store, id))
  end

  @spec ensure_account(Chain.State.t(), <<_::160>> | Wallet.t() | non_neg_integer()) ::
          Chain.Account.t()
  def ensure_account(state = %Chain.State{}, id = wallet()) do
    ensure_account(state, Wallet.address!(id))
  end

  def ensure_account(state = %Chain.State{}, id = <<_::160>>) do
    case account(state, id) do
      nil -> %Chain.Account{nonce: 0}
      acc -> acc
    end
  end

  def ensure_account(state = %Chain.State{}, id) when is_integer(id) do
    ensure_account(state, <<id::unsigned-size(160)>>)
  end

  @spec set_account(Chain.State.t(), binary(), Chain.Account.t()) :: Chain.State.t()
  def set_account(state = %Chain.State{store: store, map: map}, id = <<_::160>>, account) do
    hash = Chain.Account.hash(account)
    # store = MerkleTree.delete(store, id)
    store = MerkleTree.insert(store, id, hash)
    map = Map.put(map, hash, account)

    # Recreating map, ensuring to skip non-referenced entries
    map = for {_k, v} <- MerkleTree.to_list(store), into: %{}, do: {v, Map.fetch!(map, v)}
    %{state | store: store, map: map}
  end

  @spec delete_account(Chain.State.t(), binary()) :: Chain.State.t()
  def delete_account(state = %Chain.State{store: store, map: map}, id = <<_::160>>) do
    store = MerkleTree.delete(store, id)
    # Recreating map, ensuring to skip non-referenced entries
    map = for {_k, v} <- MerkleTree.to_list(store), into: %{}, do: {v, Map.fetch!(map, v)}
    %{state | store: store, map: map}
  end
end
