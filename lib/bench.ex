# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Bench do
  # MIX_ENV=benchmark mix run benchmark.exs
  alias Chain.Transaction

  def create_contract(x, fib) do
    wallet = Wallet.new()
    miner = Wallet.new()

    state = Chain.State.new()
    block = %Chain.Block{header: %Chain.Header{}, coinbase: miner}

    bin =
      :binary.encode_unsigned(
        0x6080604052348015600F57600080FD5B506004361060325760003560E01C806303DD1360146037578063C6C2EA17146053575B600080FD5B603D6092565B6040518082815260200191505060405180910390F35B607C60048036036020811015606757600080FD5B81019080803590602001909291905050506098565B6040518082815260200191505060405180910390F35B60005481565B6000806000815480929190600101919050555060B28260B9565B9050919050565B60006001821160CA576001905060E2565B60D46002830360B9565B60DE6001840360B9565B0190505B91905056FEA265627A7A72315820B01601A182A65AA8F84743102AD7F4B9F9C65196F3F193D5790B3EFE1DFF7A2A64736F6C634300050B0032
      )

    contract_acc = Chain.Account.new(code: bin)

    contract_addr = Wallet.address!(Wallet.new())

    user_acc =
      Chain.Account.new(
        nonce: 0,
        balance: Shell.ether(1000)
      )

    state =
      Chain.State.set_account(state, Wallet.address!(wallet), user_acc)
      |> Chain.State.set_account(contract_addr, contract_acc)

    tx = Shell.transaction(wallet, contract_addr, "fib", ["uint256"], [fib])
    tx = %{tx | nonce: 0, gasLimit: 100_000_000_000, gasPrice: 0}

    txlist =
      Enum.reduce(0..x, [], fn n, txlist ->
        [
          %{tx | nonce: tx.nonce + n}
          |> Transaction.sign(Wallet.privkey!(wallet))
          | txlist
        ]
      end)

    {state, Enum.reverse(txlist), block, contract_addr}
  end

  def increment({state, txlist, block, _addr}) do
    # Method call increment
    # state =
    Enum.reduce(txlist, state, fn tx, state ->
      {:ok, state, _rcpt} = Transaction.apply(tx, block, state)
      state
    end)

    # # Checking value of i at position 0
    # acc = Chain.State.account(state, addr)
    # len = Chain.Account.storageInteger(acc, 0)
    # IO.puts("#{length(txlist)} == #{len}")
    # ^len = length(txlist)
  end
end
