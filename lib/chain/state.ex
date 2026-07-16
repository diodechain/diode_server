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
    {:nowarn_function, clone_lazy: 1},
    {:nowarn_function, from_binary: 1}
  ]

  @enforce_keys [:accounts]
  defstruct accounts: nil, hash: nil
  @type t :: %Chain.State{accounts: CAccountMap.t(), hash: binary() | nil}

  def new() do
    %Chain.State{accounts: CAccountMap.new()}
  end

  def compact(%Chain.State{accounts: accounts} = state) do
    accounts =
      accounts
      |> CAccountMap.to_account_list()
      |> Enum.map(fn {id, acc} -> {id, Account.compact(acc)} end)
      |> Map.new()

    %Chain.State{state | accounts: accounts}
  end

  def uncompact(%Chain.State{accounts: accounts} = state) do
    {accounts, hash} = CAccountMap.uncompact_state(accounts)
    %Chain.State{state | accounts: accounts, hash: hash}
  end

  def normalize(%Chain.State{accounts: accounts} = state) do
    %{state | hash: CAccountMap.root_hash(accounts)}
  end

  def tree(%Chain.State{accounts: accounts}) do
    CAccountMap.state_trie(accounts)
  end

  def hash(%Chain.State{hash: nil} = state) do
    CAccountMap.root_hash(state.accounts)
  end

  def hash(%Chain.State{hash: hash}) do
    hash
  end

  def accounts(%Chain.State{accounts: accounts}) do
    CAccountMap.to_account_list(accounts)
  end

  @spec account(Chain.State.t(), <<_::160>>) :: Chain.Account.t() | nil
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
    accounts = CAccountMap.put_account(state.accounts, id, account)
    %{state | accounts: accounts, hash: nil}
  end

  @spec delete_account(Chain.State.t(), binary()) :: Chain.State.t()
  def delete_account(state = %Chain.State{accounts: accounts}, id = <<_::160>>) do
    %{state | accounts: CAccountMap.delete(accounts, id), hash: nil}
  end

  def difference(
        %Chain.State{accounts: accounts_a} = state_a,
        %Chain.State{accounts: accounts_b} = state_b
      ) do
    {time, result} =
      :timer.tc(fn ->
        Enum.map(CAccountMap.difference_full(accounts_a, accounts_b), fn
          {id, _side_a, _side_b, state_diff} ->
            acc_a = account(state_a, id) || ensure_account(state_a, id)
            acc_b = account(state_b, id) || ensure_account(state_b, id)

            report =
              %{}
              |> put_field_diff(:nonce, acc_a, acc_b)
              |> put_field_diff(:balance, acc_a, acc_b)
              |> put_field_diff(:code, acc_a, acc_b)

            storage_map = CAccountMap.decode_storage_diff(state_diff)

            report =
              if map_size(storage_map) > 0 do
                Map.merge(report, %{
                  state: storage_map,
                  root_hash: {Account.root_hash(acc_a), Account.root_hash(acc_b)}
                })
              else
                report
              end

            {id, report}
        end)
      end)

    if div(time, 1000) > 1000 do
      Logger.warning(
        "State diff took longer than 1s total_ms=#{div(time, 1000)} accounts=#{length(result)}"
      )
    end

    result
  end

  defp put_field_diff(report, field, acc_a, acc_b) do
    a = apply(Account, field, [acc_a])
    b = apply(Account, field, [acc_b])

    if a == b do
      report
    else
      Map.put(report, field, {a, b})
    end
  end

  def clone(%Chain.State{accounts: accounts} = state) do
    %{state | accounts: CAccountMap.clone(accounts), hash: nil}
  end

  def clone_lazy(%Chain.State{accounts: accounts} = state) do
    %{state | accounts: CAccountMap.clone_lazy(accounts), hash: nil}
  end

  def lock(%Chain.State{accounts: accounts} = state) do
    CAccountMap.lock(accounts)
    state
  end

  def apply_difference(%Chain.State{} = state, difference) do
    case CAccountMap.apply_difference(state.accounts, difference) do
      {:error, reason} ->
        raise ArgumentError, "apply_difference mismatch: #{inspect(reason)}"

      accounts ->
        %{state | accounts: accounts, hash: nil}
    end
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
