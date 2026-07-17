# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.State do
  require Logger

  @dialyzer [
    {:nowarn_function, new: 0},
    {:nowarn_function, uncompact: 1},
    {:nowarn_function, clone: 1},
    {:nowarn_function, from_binary: 1}
  ]

  @enforce_keys [:accounts]
  defstruct accounts: nil, hash: nil
  @type t :: %Chain.State{accounts: CAccountMap.t(), hash: binary() | nil}

  def new() do
    %Chain.State{accounts: CAccountMap.new()}
  end

  def compact(%Chain.State{accounts: accounts} = state) do
    %{state | accounts: CAccountMap.compact(accounts)}
  end

  def uncompact(%Chain.State{accounts: accounts} = state) do
    {accounts, hash} = CAccountMap.uncompact_state(accounts)
    %Chain.State{state | accounts: accounts, hash: hash}
  end

  def normalize(%Chain.State{accounts: accounts} = state) do
    %{state | hash: CAccountMap.root_hash(accounts)}
  end

  def state_root_hashes(%Chain.State{accounts: accounts}) do
    CAccountMap.state_root_hashes(accounts)
  end

  def get_proofs(%Chain.State{accounts: accounts}, addr) do
    CAccountMap.get_proofs(accounts, normalize_address(addr))
  end

  def storage_value(%Chain.State{accounts: accounts}, addr, key) do
    case CAccountMap.storage_get(accounts, normalize_address(addr), key) do
      nil -> <<0::unsigned-size(256)>>
      bin -> bin
    end
  end

  def storage_put_map(%Chain.State{accounts: accounts} = state, updates) do
    %{state | accounts: CAccountMap.storage_put_map(accounts, updates), hash: nil}
  end

  def storage_to_list(%Chain.State{accounts: accounts}, addr),
    do: CAccountMap.storage_to_list(accounts, normalize_address(addr))

  def storage_size(%Chain.State{accounts: accounts}, addr),
    do: CAccountMap.storage_size(accounts, normalize_address(addr))

  def storage_get_range(%Chain.State{accounts: accounts}, addr, key, count),
    do: CAccountMap.storage_get_range(accounts, normalize_address(addr), key, count)

  def storage_root_hash(%Chain.State{accounts: accounts}, addr),
    do: CAccountMap.storage_root_hash(accounts, normalize_address(addr))

  def storage_root_hashes(%Chain.State{accounts: accounts}, addr),
    do: CAccountMap.storage_root_hashes(accounts, normalize_address(addr))

  def storage_get_proofs(%Chain.State{accounts: accounts}, addr, key),
    do: CAccountMap.storage_get_proofs(accounts, normalize_address(addr), key)

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

  def normalize_address(<<_::160>> = id), do: id
  def normalize_address(id) when is_integer(id), do: <<id::unsigned-size(160)>>
  def normalize_address(id), do: Wallet.address!(id)

  @spec ensure_account(Chain.State.t(), <<_::160>> | Wallet.t() | non_neg_integer()) ::
          Chain.Account.t()
  def ensure_account(state = %Chain.State{}, id) do
    case account(state, normalize_address(id)) do
      nil -> Chain.Account.new(nonce: 0)
      acc -> acc
    end
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
        %Chain.State{accounts: accounts_a} = _state_a,
        %Chain.State{accounts: accounts_b} = _state_b
      ) do
    {time, result} =
      :timer.tc(fn ->
        Enum.map(CAccountMap.difference_full(accounts_a, accounts_b), fn
          {id, side_a, side_b, state_diff, root_a, root_b} ->
            report =
              %{}
              |> put_side_field_diff(:nonce, side_a, side_b)
              |> put_side_field_diff(:balance, side_a, side_b)
              |> put_side_field_diff(:code, side_a, side_b)

            storage_map = CAccountMap.decode_storage_diff(state_diff)

            report =
              if map_size(storage_map) > 0 do
                Map.merge(report, %{
                  state: storage_map,
                  root_hash: {decode_diff_root(root_a), decode_diff_root(root_b)}
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

  defp decode_diff_root(nil), do: empty_storage_root()
  defp decode_diff_root(<<_::binary-size(32)>> = root), do: root

  defp empty_storage_root do
    key = {__MODULE__, :empty_storage_root}

    case :persistent_term.get(key, :undefined) do
      :undefined ->
        root = CAccountMap.storage_root_hash(CAccountMap.new(), <<0::unsigned-size(160)>>)
        :persistent_term.put(key, root)
        root

      root ->
        root
    end
  end

  defp put_side_field_diff(report, field, side_a, side_b) do
    a = side_field(side_a, field)
    b = side_field(side_b, field)

    if a == b do
      report
    else
      Map.put(report, field, {a, b})
    end
  end

  defp side_field(nil, :nonce), do: 0
  defp side_field(nil, :balance), do: 0
  defp side_field(nil, :code), do: ""
  defp side_field({nonce, _balance, _code}, :nonce), do: nonce
  defp side_field({_nonce, balance, _code}, :balance) when is_integer(balance), do: balance

  defp side_field({_nonce, balance, _code}, :balance) when is_binary(balance),
    do: :binary.decode_unsigned(balance)

  defp side_field({_nonce, _balance, code}, :code), do: code

  # Writable fork for block sync and speculative paths on locked/cached peak state.
  def clone(%Chain.State{accounts: accounts} = state) do
    %{state | accounts: CAccountMap.clone(accounts), hash: nil}
  end

  # Freeze map (`frozen` only). Map storage writes reject while frozen.
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
      data = Map.get(acc, :data)

      storage =
        cond do
          data in [nil, [], %{}] -> nil
          is_map(data) -> Map.to_list(data)
          is_list(data) -> data
          true -> raise ArgumentError, "unsupported account data: #{inspect(data)}"
        end

      set_account(state, id, %Chain.Account{
        nonce: acc.nonce,
        balance: acc.balance,
        storage_root: storage,
        code: acc.code,
        map_backed: false
      })
    end)
  end
end
