# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.State do
  alias Chain.Account

  # @enforce_keys [:store]
  defstruct accounts: %{}, hash: nil, store: nil
  @type t :: %Chain.State{accounts: %{}, hash: nil}

  def new() do
    %Chain.State{}
  end

  def compact(%Chain.State{accounts: accounts} = state) do
    accounts =
      Enum.map(accounts, fn {id, acc} -> {id, Account.compact(acc)} end)
      |> Map.new()

    %Chain.State{state | accounts: accounts}
    |> Map.delete(:store)
  end

  def normalize(%Chain.State{hash: nil, accounts: accounts} = state) do
    accounts =
      Stats.tc(:accs, fn ->
        accounts
        |> Enum.map(fn {id, acc} -> {id, Account.normalize(acc)} end)
        |> Map.new()
      end)

    state = %Chain.State{state | accounts: accounts}
    tree = tree(state)
    hash = MerkleTree.root_hash(tree)

    # store: can be non-existing because of later addition to the schema
    state = Map.put(state, :store, tree)
    %Chain.State{state | hash: hash}
  end

  def normalize(%Chain.State{} = state) do
    state
  end

  # store: can be non-existing because of later addition to the schema
  def tree(%Chain.State{accounts: accounts, store: store}) when is_tuple(store) do
    Enum.reduce(MerkleTree.to_list(store), store, fn {id, _hash}, store ->
      if not Map.has_key?(accounts, id) do
        MerkleTree.delete(store, id)
      else
        store
      end
    end)
    |> do_tree(accounts)
  end

  def tree(%Chain.State{accounts: accounts}) do
    do_tree(MerkleTree.new(), accounts)
  end

  defp do_tree(store, accounts) do
    items = hash_accounts(Map.to_list(accounts))
    MerkleTree.insert_items(store, items)
  end

  def hash_accounts([]), do: []
  def hash_accounts([{id, acc} | rest]), do: [{id, Account.hash(acc)} | hash_accounts(rest)]

  def hash(%Chain.State{hash: nil} = state) do
    MerkleTree.root_hash(tree(state))
  end

  def hash(%Chain.State{hash: hash}) do
    hash
  end

  def accounts(%Chain.State{accounts: accounts}) do
    accounts
  end

  @spec account(Chain.State.t(), <<_::160>>) :: Chain.Account.t() | nil
  def account(%Chain.State{accounts: accounts}, id = <<_::160>>) do
    Map.get(accounts, id)
  end

  @spec ensure_account(Chain.State.t(), <<_::160>> | Wallet.t() | non_neg_integer()) ::
          Chain.Account.t()
  def ensure_account(state = %Chain.State{}, id = <<_::160>>) do
    case account(state, id) do
      nil -> Chain.Account.new(nonce: 0)
      acc -> acc
    end
  end

  def ensure_account(state = %Chain.State{}, id) when is_integer(id) do
    ensure_account(state, <<id::unsigned-size(160)>>)
  end

  def ensure_account(state = %Chain.State{}, id) do
    ensure_account(state, Wallet.address!(id))
  end

  @spec set_account(Chain.State.t(), binary(), Chain.Account.t()) :: Chain.State.t()
  def set_account(state = %Chain.State{accounts: accounts}, id = <<_::160>>, account) do
    %{state | accounts: Map.put(accounts, id, account), hash: nil}
  end

  @spec delete_account(Chain.State.t(), binary()) :: Chain.State.t()
  def delete_account(state = %Chain.State{accounts: accounts}, id = <<_::160>>) do
    %{state | accounts: Map.delete(accounts, id), hash: nil}
  end

  def difference(
        %Chain.State{accounts: accounts_a} = state_a,
        %Chain.State{accounts: accounts_b} = state_b
      ) do
    diff =
      MerkleTree.difference(
        MapMerkleTree.from_map(accounts_a),
        MapMerkleTree.from_map(accounts_b)
      )

    Enum.map(diff, fn {id, _} ->
      acc_a = ensure_account(state_a, id)
      acc_b = ensure_account(state_b, id)

      delta = %{
        nonce: {Account.nonce(acc_a), Account.nonce(acc_b)},
        balance: {Account.balance(acc_a), Account.balance(acc_b)},
        code: {Account.code(acc_a), Account.code(acc_b)}
      }

      report = %{state: MerkleTree.difference(Account.tree(acc_a), Account.tree(acc_b))}

      report =
        Enum.reduce(delta, report, fn {key, {a, b}}, report ->
          if a == b do
            report
          else
            Map.put(report, key, {a, b})
          end
        end)

      {id, report}
    end)
  end

  def apply_difference(%Chain.State{} = state, difference) do
    Enum.reduce(difference, state, fn {id, report}, state ->
      acc = ensure_account(state, id)

      acc =
        Enum.reduce(report, acc, fn {key, delta}, acc ->
          case key do
            :state ->
              Enum.reduce(delta, acc, fn {key, {a, b}}, acc ->
                tree = Account.tree(acc)
                ^a = MerkleTree.get(tree, key)
                tree = MerkleTree.insert(tree, key, b)
                Account.put_tree(acc, tree)
              end)

            _other ->
              {a, b} = delta
              ^a = apply(Account, key, [acc])
              %{acc | key => b}
          end
        end)

      set_account(state, id, acc)
    end)
  end

  # ========================================================
  # File Import / Export
  # ========================================================
  @spec to_binary(Chain.State.t()) :: binary
  def to_binary(state) do
    Enum.reduce(accounts(state), Map.new(), fn {id, acc}, map ->
      Map.put(map, id, %{
        nonce: acc.nonce,
        balance: acc.balance,
        data: Account.tree(acc) |> MerkleTree.to_list(),
        code: acc.code
      })
    end)
    |> BertInt.encode!()
  end

  def from_binary(bin) do
    map = BertInt.decode!(bin)

    Enum.reduce(map, new(), fn {id, acc}, state ->
      set_account(state, id, %Chain.Account{
        nonce: acc.nonce,
        balance: acc.balance,
        storage_root: MapMerkleTree.new() |> MerkleTree.insert_items(acc.data),
        code: acc.code
      })
    end)
  end
end
