# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Shell do
  @moduledoc """
    TODO: This module is too heavily dependent on Network.Rpc, need to think about
    moving either Module

    Examples:

    me = Diode.miner() |> Wallet.address!()
    Shell.get_balance(me)

    fleetContract = Base16.decode("0x6728c7bea74db60c2fb117c15de28b0b0686c389")
    Shell.call(fleetContract, "accountant")

    registryContract = Diode.registry_address()
    Shell.call(registryContract, "ContractStake", ["address"], [fleetContract])

    addr = Chain.GenesisFactory.genesis_accounts |> hd |> elem(0)
    Shell.call_from(Wallet.from_address(addr), registryContract, "ContractStake", ["address"], [fleetContract])
  """
  def call(address, name, types \\ [], values \\ [], opts \\ [])
      when is_list(types) and is_list(values) do
    call_from(Diode.miner(), address, name, types, values, opts)
  end

  def call_from(wallet, address, name, types \\ [], values \\ [], opts \\ [])
      when is_list(types) and is_list(values) do
    opts =
      opts
      |> Keyword.put_new(:gas, Chain.gas_limit() * 100)
      |> Keyword.put_new(:gasPrice, 0)

    tx = transaction(wallet, address, name, types, values, opts, false)
    blockRef = Keyword.get(opts, :blockRef, "latest")
    call_tx(tx, blockRef)
  end

  def call_tx(tx, blockRef) do
    block = Network.Rpc.get_block(blockRef)
    state = Chain.Block.state(block)
    {:ok, _state, rcpt} = Chain.Transaction.apply(tx, block, state, static: true)

    ret =
      case rcpt.msg do
        :evmc_revert -> ABI.decode_revert(rcpt.evmout)
        _ -> rcpt.evmout
      end

    {ret, rcpt.gas_used}
  end

  def submit_from(wallet, address, name, types, values, opts \\ [])
      when is_list(types) and is_list(values) do
    tx = transaction(wallet, address, name, types, values, opts)
    Chain.Pool.add_transaction(tx)
  end

  def transaction(wallet, address, name, types, values, opts \\ [], sign \\ true)
      when is_list(types) and is_list(values) do
    opts =
      opts
      |> Keyword.put_new(:gas, Chain.gas_limit())
      |> Keyword.put_new(:gasPrice, 0)
      |> Keyword.put(:to, address)
      |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.new()

    # https://solidity.readthedocs.io/en/v0.4.24/abi-spec.html
    callcode = ABI.encode_call(name, types, values)
    Network.Rpc.create_transaction(wallet, callcode, opts, sign)
  end

  def get_balance(address) do
    Chain.peak_state()
    |> Chain.State.ensure_account(address)
    |> Chain.Account.balance()
  end

  @spec get_miner_stake(binary()) :: non_neg_integer()
  def get_miner_stake(address) do
    {value, _gas} =
      call(Diode.registry_address(), "MinerValue", ["uint8", "address"], [0, address])

    :binary.decode_unsigned(value)
  end

  def get_slot(address, slot) do
    Chain.peak_state()
    |> Chain.State.ensure_account(address)
    |> Chain.Account.storage_value(slot)
  end

  def get_code(address) do
    Chain.peak_state()
    |> Chain.State.ensure_account(address)
    |> Chain.Account.code()
  end

  def profile_import() do
    Stats.toggle_print()
    :observer.start()
    spawn(fn -> Chain.import_blocks("blocks.dat") end)
  end

  def ether(x), do: 1000 * finney(x)
  def finney(x), do: 1000 * szabo(x)
  def szabo(x), do: 1000 * gwei(x)
  def gwei(x), do: 1000 * mwei(x)
  def mwei(x), do: 1000 * kwei(x)
  def kwei(x), do: 1000 * wei(x)
  def wei(x) when is_integer(x), do: x
end
