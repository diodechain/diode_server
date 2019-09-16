defmodule Shell do
  @moduledoc """
    TODO: This module is too heavily dependent on Network.Rpc, need to think about
    moving either Module

    Examples:

    me = Diode.miner() |> Wallet.address!()
    Shell.get_balance(me)

    fleetContract = Base16.decode("0x6728c7bea74db60c2fb117c15de28b0b0686c389")
    Shell.call(fleetContract, "accountant")

    registryContract = Diode.registryAddress()
    Shell.call(registryContract, "ContractStake", ["address"], [fleetContract])

    wallet = Chain.GenesisFactory.genesis_accounts |> hd |> elem(0)
    Shell.call_from(wallet, registryContract, "ContractStake", ["address"], [fleetContract])
  """
  def call(address, name, types \\ [], values \\ [], opts \\ [])
      when is_list(types) and is_list(values) do
    call_from(Store.wallet(), address, name, types, values, opts)
  end

  def call_from(wallet, address, name, types \\ [], values \\ [], opts \\ [])
      when is_list(types) and is_list(values) do
    opts =
      opts
      |> Keyword.put_new(:gas, Chain.gasLimit() * 100)
      |> Keyword.put_new(:gasPrice, 0)

    tx = transaction(wallet, address, name, types, values, opts)

    blockRef = Keyword.get(opts, :blockRef, "latest")
    block = Network.Rpc.getBlock(blockRef)
    state = Chain.Block.state(block)
    {:ok, _state, rcpt} = Chain.Transaction.apply(tx, block, state)

    ret =
      case rcpt.msg do
        :revert -> ABI.decode_revert(rcpt.evmout)
        _ -> rcpt.evmout
      end

    {ret, rcpt.gas_used}
  end

  def submit_from(wallet, address, name, types, values, opts \\ [])
      when is_list(types) and is_list(values) do
    tx = transaction(wallet, address, name, types, values, opts)
    Chain.Pool.add_transaction(tx)
  end

  def transaction(wallet, address, name, types, values, opts \\ [])
      when is_list(types) and is_list(values) do
    # https://solidity.readthedocs.io/en/v0.4.24/abi-spec.html
    fun = ABI.encode_spec(name, types)
    args = ABI.encode_args(types, values)
    callcode = fun <> args

    opts =
      opts
      |> Keyword.put_new(:gas, Chain.gasLimit())
      |> Keyword.put_new(:gasPrice, 0)
      |> Keyword.put(:to, address)
      |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.new()

    Network.Rpc.create_transaction(wallet, callcode, opts)
  end

  def get_balance(address) do
    Chain.peakState()
    |> Chain.State.ensure_account(address)
    |> Chain.Account.balance()
  end

  @spec get_miner_stake(binary()) :: non_neg_integer()
  def get_miner_stake(address) do
    {value, _gas} =
      call(Diode.registryAddress(), "MinerValue", ["uint8", "address"], [0, address])

    :binary.decode_unsigned(value)
  end

  def get_slot(address, slot) do
    Chain.peakState()
    |> Chain.State.ensure_account(address)
    |> Chain.Account.storageValue(slot)
  end

  def get_code(address) do
    Chain.peakState()
    |> Chain.State.ensure_account(address)
    |> Chain.Account.code()
  end

  def ether(x), do: 1000 * finney(x)
  def finney(x), do: 1000 * szabo(x)
  def szabo(x), do: 1000 * gwei(x)
  def gwei(x), do: 1000 * mwei(x)
  def mwei(x), do: 1000 * kwei(x)
  def kwei(x), do: 1000 * wei(x)
  def wei(x) when is_integer(x), do: x
end
