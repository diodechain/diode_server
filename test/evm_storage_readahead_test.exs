# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule EvmStorageReadaheadTest do
  use ExUnit.Case
  alias Chain.Transaction
  alias Chain.TransactionReceipt

  test "contract storage sload works with gs read-ahead response" do
    from_wallet = Wallet.new()
    priv = Wallet.privkey!(from_wallet)
    miner = Wallet.new()

    state = Chain.State.new()
    block = %Chain.Block{header: %Chain.Header{}, coinbase: miner}

    bin =
      :binary.encode_unsigned(
        0xF9013807843B9ACA0083019EC18080B8E7608060405234801561001057600080FD5B5060C88061001F6000396000F3FE6080604052600436106043576000357C010000000000000000000000000000000000000000000000000000000090048063D09DE08A146048578063E5AA3D5814605C575B600080FD5B348015605357600080FD5B50605A6084565B005B348015606757600080FD5B50606E6096565B6040518082815260200191505060405180910390F35B60016000808282540192505081905550565B6000548156FEA165627A7A72305820A5336A14AEA4B012AC2DE830E9CA97BB8E8FD52A7D9F2F497EBAE715237A897900292BA0AF5F04CB66F5EC4FD9B2498682150078C06D021B960EFCF99F34AFE7741829C0A04F1CC90CB4D8A39213D27EAF98570967370D086B51E825B40E95C3BFD9635818
      )

    ctx = %{Transaction.from_rlp(bin) | gasLimit: 100_000_000}
    ctx = Transaction.sign(ctx, priv)

    user_acc =
      Chain.Account.new(
        nonce: ctx.nonce,
        balance: ctx.value + 2 * Transaction.gas_limit(ctx) * Transaction.gas_price(ctx)
      )

    state = Chain.State.set_account(state, Wallet.address!(from_wallet), user_acc)

    {:ok, state, %TransactionReceipt{msg: :ok}} = Transaction.apply(ctx, block, state)

    contract = Transaction.new_contract_address(ctx)
    acc = Chain.State.account(state, contract)
    assert Chain.Account.storage_value(acc, 0) |> :binary.decode_unsigned() == 0

    tx =
      %{
        Transaction.from_rlp(
          :binary.encode_unsigned(
            0xF86708843B9ACA0082A2A0949E0A6D367859C47E7895557D5F763B954952FCB08084D09DE08A2CA0F40915BA7822D7CDA5C42B530E21616249E700082A4E7401E8C62775E7C5E219A01BE95441D88652AE5ED7E57ECF837EB1DDF844024E55E5EFB6CD2AA555C913DD
          )
        )
        | gasLimit: 100_000_000
      }
      |> Map.put(:nonce, ctx.nonce + 1)
      |> Map.put(:to, contract)
      |> Transaction.sign(priv)

    {:ok, state, %TransactionReceipt{msg: :ok}} = Transaction.apply(tx, block, state)

    acc = Chain.State.account(state, contract)
    assert Chain.Account.storage_value(acc, 0) |> :binary.decode_unsigned() == 1
  end
end
