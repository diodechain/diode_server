# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.State do
  require Logger
  alias Chain.Account

  @dialyzer [
    {:nowarn_function, new: 0},
    {:nowarn_function, uncompact: 1},
    {:nowarn_function, clone: 1},
    {:nowarn_function, from_binary: 1}
  ]

  @enforce_keys [:accounts]
  defstruct accounts: nil, hash: nil, store: nil
  @type t :: %Chain.State{accounts: CAccountMap.t(), hash: any(), store: any()}

  def new() do
    %Chain.State{accounts: CAccountMap.new()}
  end

  def compact(%Chain.State{accounts: accounts} = state) when is_map(accounts) do
    accounts =
      Enum.map(accounts, fn {id, acc} -> {id, Account.compact(acc)} end)
      |> Map.new()

    %Chain.State{state | accounts: accounts}
    |> Map.delete(:store)
  end

  def compact(%Chain.State{accounts: accounts} = state) do
    accounts =
      accounts
      |> CAccountMap.to_account_list()
      |> Enum.map(fn {id, acc} -> {id, Account.compact(acc)} end)
      |> Map.new()

    %Chain.State{state | accounts: accounts}
    |> Map.delete(:store)
  end

  def uncompact(%Chain.State{accounts: accounts} = state) do
    {accounts, store, hash} = CAccountMap.uncompact_state(accounts)

    %Chain.State{state | accounts: accounts, hash: hash}
    |> Map.put(:store, store)
  end

  def normalize(%Chain.State{} = state) do
    tree = tree(state)
    hash = CMerkleTree.root_hash(tree)
    state = Map.put(state, :store, tree)
    %Chain.State{} = state
    %{state | hash: hash}
  end

  def tree(%Chain.State{store: store}) when store != nil do
    store
  end

  def tree(%Chain.State{accounts: accounts}) do
    accounts
    |> account_list()
    |> Enum.reduce(%{}, fn {id, acc}, map ->
      Map.put(map, id, Account.hash(acc))
    end)
    |> CMerkleTree.from_map()
  end

  def hash(%Chain.State{hash: nil} = state) do
    CMerkleTree.root_hash(tree(state))
  end

  def hash(%Chain.State{hash: hash}) do
    hash
  end

  def accounts(%Chain.State{accounts: accounts}) when is_map(accounts) do
    accounts
  end

  def accounts(%Chain.State{accounts: accounts}) do
    CAccountMap.to_account_list(accounts)
  end

  @spec account(Chain.State.t(), <<_::160>>) :: Chain.Account.t() | nil
  def account(%Chain.State{accounts: accounts}, id = <<_::160>>) when is_map(accounts) do
    Map.get(accounts, id)
  end

  def account(%Chain.State{accounts: accounts}, id = <<_::160>>) do
    CAccountMap.get_account(accounts, id)
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
  def set_account(state, id = <<_::160>>, account) do
    tree = CMerkleTree.insert(tree(state), id, Account.hash(account))
    accounts = put_account_in(state.accounts, id, account)
    %{state | accounts: accounts, hash: nil, store: tree}
  end

  @spec delete_account(Chain.State.t(), binary()) :: Chain.State.t()
  def delete_account(state = %Chain.State{accounts: accounts}, id = <<_::160>>)
      when is_map(accounts) do
    %{state | accounts: Map.delete(accounts, id), hash: nil, store: nil}
  end

  def delete_account(state = %Chain.State{accounts: accounts}, id = <<_::160>>) do
    %{state | accounts: CAccountMap.delete(accounts, id), hash: nil, store: nil}
  end

  def difference(
        %Chain.State{accounts: accounts_a} = state_a,
        %Chain.State{accounts: accounts_b} = state_b
      ) do
    diff = account_maps_diff(accounts_a, accounts_b)

    Enum.map(diff, fn {id, {acc_a, acc_b}} ->
      acc_a = acc_a || ensure_account(state_a, id)
      acc_b = acc_b || ensure_account(state_b, id)

      {time, report} =
        :timer.tc(fn ->
          delta = %{
            nonce: {Account.nonce(acc_a), Account.nonce(acc_b)},
            balance: {Account.balance(acc_a), Account.balance(acc_b)},
            code: {Account.code(acc_a), Account.code(acc_b)}
          }

          report =
            Enum.reduce(delta, %{}, fn {key, {a, b}}, report ->
              if a == b do
                report
              else
                Map.put(report, key, {a, b})
              end
            end)

          state_diff = CMerkleTree.difference(Account.tree(acc_a), Account.tree(acc_b))

          if map_size(state_diff) > 0 do
            Map.merge(report, %{
              state: state_diff,
              root_hash: {Account.root_hash(acc_a), Account.root_hash(acc_b)}
            })
          else
            report
          end
        end)

      if div(time, 1000) > 1000 do
        Logger.warning(
          "State diff took longer than 1s #{inspect({Base16.encode(id), div(time, 1000), map_size(report)})}"
        )
      end

      {id, report}
    end)
  end

  def clone(%Chain.State{accounts: accounts} = state) do
    state
    |> Map.put(:accounts, clone_accounts(accounts))
    |> clone_store()
  end

  def lock(%Chain.State{accounts: accounts} = state) when is_map(accounts) do
    for {_id, acc} <- account_list(accounts) do
      do_lock(Account.tree(acc))
    end

    do_lock(Map.get(state, :store))
    state
  end

  def lock(%Chain.State{accounts: accounts} = state) do
    CAccountMap.lock(accounts, Map.get(state, :store))
    state
  end

  defp do_lock(nil), do: nil
  defp do_lock(root), do: CMerkleTree.lock(root)

  def apply_difference(%Chain.State{} = state, difference) do
    Enum.reduce(difference, state, fn {id, report}, state ->
      oacc = acc = ensure_account(state, id)

      {state_update, report} = Map.pop(report, :state, %{})

      acc =
        Enum.reduce(state_update, acc, fn {key, {a, b}}, acc ->
          tree = Account.tree(acc)
          ^a = CMerkleTree.get(tree, key)
          tree = CMerkleTree.insert(tree, key, b)
          Account.put_tree(acc, tree)
        end)

      acc =
        report
        |> Enum.reject(fn {key, _delta} -> key == :root_hash end)
        |> Enum.reduce(acc, fn {key, delta}, acc ->
          {a, b} = delta
          ret = apply(Account, key, [oacc])
          ^a = ret
          %{acc | key => b}
        end)

      set_account(state, id, acc)
    end)
  end

  def from_binary(bin) do
    map = BertInt.decode!(bin)

    Enum.reduce(map, new(), fn {id, acc}, state ->
      set_account(state, id, %Chain.Account{
        nonce: acc.nonce,
        balance: acc.balance,
        storage_root: CMerkleTree.new() |> CMerkleTree.insert_items(acc.data),
        code: acc.code
      })
    end)
  end

  defp account_list(accounts) when is_map(accounts) do
    Map.to_list(accounts)
  end

  defp account_list(accounts) do
    CAccountMap.to_account_list(accounts)
  end

  defp account_maps_diff(accounts_a, accounts_b) when is_map(accounts_a) or is_map(accounts_b) do
    CMerkleTree.list_difference(account_list(accounts_a), account_list(accounts_b))
  end

  defp account_maps_diff(accounts_a, accounts_b) do
    CAccountMap.list_difference(accounts_a, accounts_b)
  end

  defp put_account_in(accounts, id, account) when is_map(accounts) do
    Map.put(accounts, id, account)
  end

  defp put_account_in(accounts, id, account) do
    CAccountMap.put_account(accounts, id, account)
  end

  defp clone_accounts(accounts) when is_map(accounts) do
    Map.new(accounts, fn {id, acc} -> {id, Account.clone(acc)} end)
  end

  defp clone_accounts(accounts), do: CAccountMap.clone(accounts)

  defp clone_store(%Chain.State{} = state) do
    case Map.get(state, :store) do
      nil -> state
      store -> %{state | store: CMerkleTree.clone(store)}
    end
  end
end
