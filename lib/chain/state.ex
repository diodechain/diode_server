# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.State do
  require Logger
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

  def uncompact(%Chain.State{accounts: accounts} = state) do
    # IO.inspect(hash, label: "uncompact(state.hash)")

    accounts =
      Enum.reduce(accounts, %{}, fn {id, acc}, accounts ->
        Map.put(accounts, id, Account.uncompact(acc))
      end)

    state = %Chain.State{state | accounts: accounts}
    tree = tree(state)
    new_hash = CMerkleTree.root_hash(tree)

    # if new_hash != hash do
    #   Logger.error("Old hash != new_hash, label: "uncompact(new state.hash)")
    # end

    # store: can be non-existing because of later addition to the schema
    %Chain.State{state | hash: new_hash}
    |> Map.put(:store, tree)
  end

  def normalize(%Chain.State{} = state) do
    tree = tree(state)
    hash = CMerkleTree.root_hash(tree)
    # store: can be non-existing because of later addition to the schema
    state = Map.put(state, :store, tree)
    %Chain.State{state | hash: hash}
  end

  # store: can be non-existing because of later addition to the schema
  def tree(%Chain.State{store: store}) when store != nil do
    store
  end

  def tree(%Chain.State{accounts: accounts}) do
    accounts
    |> Enum.reduce(%{}, fn {id, acc}, map ->
      hash = Account.hash(acc)
      Map.put(map, id, hash)
    end)
    |> CMerkleTree.from_map()
  end

  def hash(%Chain.State{hash: nil} = state) do
    CMerkleTree.root_hash(tree(state))
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
    %{state | accounts: Map.put(accounts, id, account), hash: nil, store: nil}
  end

  @spec delete_account(Chain.State.t(), binary()) :: Chain.State.t()
  def delete_account(state = %Chain.State{accounts: accounts}, id = <<_::160>>) do
    %{state | accounts: Map.delete(accounts, id), hash: nil, store: nil}
  end

  def difference(
        %Chain.State{accounts: accounts_a} = state_a,
        %Chain.State{accounts: accounts_b} = state_b
      ) do
    diff = CMerkleTree.list_difference(accounts_a, accounts_b)

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
    new_state = %Chain.State{
      state
      | accounts: Enum.map(accounts, fn {id, acc} -> {id, Account.clone(acc)} end) |> Map.new()
    }

    case Map.get(state, :store) do
      nil -> new_state
      store -> %Chain.State{new_state | store: CMerkleTree.clone(store)}
    end
  end

  def apply_difference(%Chain.State{} = state, difference) do
    Enum.reduce(difference, state, fn {id, report}, state ->
      oacc = acc = ensure_account(state, id)

      {state_update, report} = Map.pop(report, :state, %{})

      acc =
        Enum.reduce(state_update, acc, fn {key, {a, b}}, acc ->
          tree = Account.tree(acc)

          # if a != CMerkleTree.get(tree, key) do
          #   IO.inspect({key, {a, b}, CMerkleTree.to_list(tree), difference},
          #     label: "apply_difference"
          #   )
          # end

          ^a = CMerkleTree.get(tree, key)
          tree = CMerkleTree.insert(tree, key, b)
          Account.put_tree(acc, tree)
        end)

      acc =
        report
        # Removed root_hash from the %Account module
        |> Enum.reject(fn {key, _delta} -> key == :root_hash end)
        |> Enum.reduce(acc, fn {key, delta}, acc ->
          {a, b} = delta
          ret = apply(Account, key, [oacc])

          # if ret != a do
          #   IO.inspect({key, {a, b}, ret}, label: "apply_difference(2)")
          # end

          ^a = ret
          %{acc | key => b}
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
        data: Account.tree(acc) |> CMerkleTree.to_list(),
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
        storage_root: CMerkleTree.new() |> CMerkleTree.insert_items(acc.data),
        code: acc.code
      })
    end)
  end
end
