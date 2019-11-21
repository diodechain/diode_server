# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Chain.State do
  import Wallet

  @enforce_keys [:store]
  defstruct store: nil

  def init() do
    Store.create_table!(:state_accounts, [:hash, :account])
  end

  def new() do
    %Chain.State{store: MnesiaMerkleTree.new()}
  end

  def restore(state_root) do
    {:ok, store} = MnesiaMerkleTree.restore(state_root)
    %Chain.State{store: store}
  end

  def difference(%Chain.State{store: a} = state_a, %Chain.State{store: b} = state_b) do
    diff = MerkleTree.difference(a, b)

    Enum.map(diff, fn {id, _} ->
      acc_a = Chain.State.account(state_a, id)
      acc_b = Chain.State.account(state_b, id)
      {id, MerkleTree.difference(acc_a.storage_root, acc_b.storage_root)}
    end)
  end

  def restore?(state_root) do
    case MnesiaMerkleTree.restore(state_root) do
      {:ok, store} -> %Chain.State{store: store}
      {:error, _reason} -> nil
    end
  end

  def hash(%Chain.State{store: tree}) do
    MerkleTree.root_hash(tree)
  end

  def accounts(%Chain.State{store: store}) do
    MerkleTree.to_list(store)
    |> Enum.map(fn {key, value} -> {key, from_key(value)} end)
    |> Map.new()
  end

  @spec account(Chain.State.t(), <<_::160>>) :: Chain.Account.t() | nil
  def account(%Chain.State{store: store}, id = <<_::160>>) do
    from_key(MerkleTree.get(store, id))
  end

  @spec ensure_account(Chain.State.t(), <<_::160>> | Wallet.t() | non_neg_integer()) ::
          Chain.Account.t()
  def ensure_account(state = %Chain.State{}, id = wallet()) do
    ensure_account(state, Wallet.address!(id))
  end

  def ensure_account(state = %Chain.State{}, id = <<_::160>>) do
    case account(state, id) do
      nil -> Chain.Account.new(nonce: 0)
      acc -> acc
    end
  end

  def ensure_account(state = %Chain.State{}, id) when is_integer(id) do
    ensure_account(state, <<id::unsigned-size(160)>>)
  end

  @spec set_account(Chain.State.t(), binary(), Chain.Account.t()) :: Chain.State.t()
  def set_account(state = %Chain.State{store: store}, id = <<_::160>>, account) do
    hash = Chain.Account.hash(account)
    store = MerkleTree.insert(store, id, hash)

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        case :mnesia.read(:state_accounts, hash) do
          [{:state_accounts, ^hash, ^account}] -> :ok
          [] -> :mnesia.write({:state_accounts, hash, account})
        end
      end)

    %{state | store: store}
  end

  @spec delete_account(Chain.State.t(), binary()) :: Chain.State.t()
  def delete_account(state = %Chain.State{store: store}, id = <<_::160>>) do
    store = MerkleTree.delete(store, id)
    %{state | store: store}
  end

  # ========================================================
  # Internal Mnesia Specific
  # ========================================================
  defp from_key(nil), do: nil

  defp from_key(mnesia_key) when is_binary(mnesia_key) do
    [{:state_accounts, ^mnesia_key, account}] =
      if :mnesia.is_transaction() do
        :mnesia.read(:state_accounts, mnesia_key)
      else
        :mnesia.dirty_read(:state_accounts, mnesia_key)
      end

    account
  end
end
