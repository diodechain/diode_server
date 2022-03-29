# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule RpcTest do
  use ExUnit.Case, async: false
  alias Chain.Account
  alias Chain.State
  alias Chain.Transaction
  alias Chain.Worker
  alias Network.Rpc

  setup_all do
    TestHelper.reset()
  end

  test "trace_replayBlockTransactions" do
    {200, %{"result" => _ret}} = rpc("trace_replayBlockTransactions", ["latest", ["trace"]])
    {200, %{"result" => _ret}} = rpc("trace_replayBlockTransactions", ["earliest", ["trace"]])
  end

  test "eth_getBlockByNumber" do
    {200, %{"result" => _ret}} = rpc("eth_getBlockByNumber", [0, false])
    {200, %{"result" => _ret}} = rpc("eth_getBlockByNumber", [1, false])
    {404, %{"message" => _ret}} = rpc("eth_getBlockByNumber", [150, false])
    {200, %{"result" => _ret}} = rpc("eth_getBlockByNumber", ["earliest", false])
    {200, %{"result" => _ret}} = rpc("eth_getBlockByNumber", ["latest", false])
  end

  test "transaction ordering" do
    [from, to] = Diode.wallets() |> Enum.reverse() |> Enum.take(2)

    before = Chain.with_peak_state(fn state -> state end)

    from_acc = State.ensure_account(before, from)
    to_acc = State.ensure_account(before, to)
    nonce = from_acc |> Account.nonce()

    Worker.set_mode(:disabled)

    to = Wallet.address!(to)

    [tx1, tx2, tx3] =
      Enum.map(0..2, fn i ->
        Rpc.create_transaction(from, <<"">>, %{
          "value" => 1000,
          "nonce" => nonce + i,
          "to" => to,
          "gasPrice" => 0
        })
      end)

    # Ordering in wrong nonce order
    txs = [tx2, tx1, tx3]

    Enum.each(txs, fn tx ->
      {200, %{"result" => txhash}} = rpc("eth_sendRawTransaction", [to_rlp(tx)])
      assert txhash == Base16.encode(Transaction.hash(tx))
    end)

    Worker.set_mode(:poll)
    Worker.work()

    # Checking values now after transfer
    result = Chain.with_peak_state(fn state -> state end)
    from_acc2 = State.ensure_account(result, from)
    to_acc2 = State.ensure_account(result, to)

    assert Chain.Pool.proposal() == []
    assert Account.nonce(from_acc2) == nonce + length(txs)
    assert Account.balance(from_acc) - Account.balance(from_acc2) == 1000 * length(txs)
    assert Account.balance(to_acc2) - Account.balance(to_acc) == 1000 * length(txs)
  end

  test "receipt" do
    tx = prepare_transaction()

    hash = Transaction.hash(tx) |> Base16.encode()
    from = Transaction.from(tx) |> Base16.encode()
    to = Transaction.to(tx) |> Base16.encode()

    ret = rpc("eth_getTransactionReceipt", [hash])

    assert {200,
            %{
              "id" => 1,
              "jsonrpc" => "2.0",
              "result" => %{
                "blockNumber" => "0x03",
                "contractAddress" => nil,
                "cumulativeGasUsed" => _variable,
                "from" => ^from,
                "gasUsed" => "0x5208",
                "logs" => [],
                "logsBloom" =>
                  "0x0000000000000000000000000000000000000000000000000000000000000000",
                "status" => "0x01",
                "to" => ^to,
                "transactionHash" => ^hash,
                "transactionIndex" => "0x00"
              }
            }} = ret
  end

  test "getblock" do
    tx = prepare_transaction()
    hash = Transaction.hash(tx) |> Base16.encode()
    ret = rpc("eth_getBlockByNumber", [Chain.peak(), false])

    assert {200,
            %{
              "id" => 1,
              "jsonrpc" => "2.0",
              "result" => %{
                "transactions" => txs
              }
            }} = ret

    assert Enum.member?(txs, hash)
  end

  defp to_rlp(tx) do
    tx |> Transaction.to_rlp() |> Rlp.encode!() |> Base16.encode()
  end

  defp prepare_transaction() do
    [from, to] = Diode.wallets() |> Enum.reverse() |> Enum.take(2)
    # Worker.set_mode(:disabled)

    tx =
      Rpc.create_transaction(from, <<"">>, %{
        "value" => 1000,
        "to" => Wallet.address!(to),
        "gasPrice" => 0
      })

    {200, %{"result" => txhash}} = rpc("eth_sendRawTransaction", [to_rlp(tx)])
    assert txhash == Base16.encode(Transaction.hash(tx))

    # Worker.set_mode(:poll)
    tx
  end

  def rpc(method, params) do
    Rpc.handle_jsonrpc(%{"method" => method, "params" => params, "id" => 1})
  end
end
