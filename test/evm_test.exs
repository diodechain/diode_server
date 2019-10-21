defmodule EvmTest do
  use ExUnit.Case
  alias Chain.Transaction
  alias Chain.TransactionReceipt

  test "init" do
    evm = Evm.init()
    {:ok, _ret} = Evm.eval(evm)
  end

  test "create contract" do
    wallet = Wallet.new()
    priv = Wallet.privkey!(wallet)
    miner = Wallet.new()

    state = Chain.State.new()
    block = %Chain.Block{header: %Chain.Header{miner_pubkey: Wallet.pubkey!(miner)}}

    #     pragma solidity >=0.4.22 <0.6.0;

    # contract Test {
    #     int public i;

    #     function increment() public {
    #         i+=1;
    #     }
    # }

    # deploy contract:
    # method: eth_sendRawTransaction
    bin =
      :binary.encode_unsigned(
        0xF9013807843B9ACA0083019EC18080B8E7608060405234801561001057600080FD5B5060C88061001F6000396000F3FE6080604052600436106043576000357C010000000000000000000000000000000000000000000000000000000090048063D09DE08A146048578063E5AA3D5814605C575B600080FD5B348015605357600080FD5B50605A6084565B005B348015606757600080FD5B50606E6096565B6040518082815260200191505060405180910390F35B60016000808282540192505081905550565B6000548156FEA165627A7A72305820A5336A14AEA4B012AC2DE830E9CA97BB8E8FD52A7D9F2F497EBAE715237A897900292BA0AF5F04CB66F5EC4FD9B2498682150078C06D021B960EFCF99F34AFE7741829C0A04F1CC90CB4D8A39213D27EAF98570967370D086B51E825B40E95C3BFD9635818
      )

    ## Prepare: Create Origin Account and give it some balance:
    ctx = %{Transaction.from_rlp(bin) | gasLimit: 100_000_000}
    ctx = Transaction.sign(ctx, priv)

    user_acc = %Chain.Account{
      nonce: ctx.nonce,
      balance: ctx.value + 2 * Transaction.gas_limit(ctx) * Transaction.gas_price(ctx)
    }

    assert Wallet.pubkey!(Transaction.origin(ctx)) == Wallet.pubkey!(wallet)

    state = Chain.State.set_account(state, Wallet.address!(wallet), user_acc)

    # Fail test 1: Too little balance
    ctx_fail = %{ctx | gasLimit: Transaction.gas_limit(ctx) * 1_000_000} |> Transaction.sign(priv)
    assert {:error, :not_enough_balance} == Transaction.apply(ctx_fail, block, state)

    # Fail test 2: Too little gas
    ctx_fail = %{ctx | gasLimit: 1} |> Transaction.sign(priv)

    {:ok, _state, %TransactionReceipt{msg: :evmc_out_of_gas}} =
      Transaction.apply(ctx_fail, block, state)

    {:ok, state, %TransactionReceipt{msg: :ok}} = Transaction.apply(ctx, block, state)

    # Checking value of i at position 0
    acc = Chain.State.account(state, Transaction.new_contract_address(ctx))
    value = Chain.Account.storageInteger(acc, 0)
    assert value == 0

    # Method call increment
    bin =
      :binary.encode_unsigned(
        0xF86708843B9ACA0082A2A0949E0A6D367859C47E7895557D5F763B954952FCB08084D09DE08A2CA0F40915BA7822D7CDA5C42B530E21616249E700082A4E7401E8C62775E7C5E219A01BE95441D88652AE5ED7E57ECF837EB1DDF844024E55E5EFB6CD2AA555C913DD
      )

    tx = %{Transaction.from_rlp(bin) | gasLimit: 100_000_000}
    tx = %{tx | nonce: ctx.nonce + 1, to: Transaction.new_contract_address(ctx)}
    tx = Transaction.sign(tx, priv)

    assert Wallet.pubkey!(Transaction.origin(tx)) == Wallet.pubkey!(wallet)

    # Fail test 3: value on non_payable method
    tx_fail = %{tx | value: 1} |> Transaction.sign(priv)

    {:ok, _state, %TransactionReceipt{msg: :evmc_revert}} =
      Transaction.apply(tx_fail, block, state)

    {:ok, state, %TransactionReceipt{msg: :ok, evmout: evmout}} =
      Transaction.apply(tx, block, state)

    assert evmout == ""

    # Checking value of i at position 0
    acc = Chain.State.account(state, Transaction.new_contract_address(ctx))
    value = Chain.Account.storageInteger(acc, 0)
    assert value == 1
  end
end
