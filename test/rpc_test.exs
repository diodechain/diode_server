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

  test "eth_get_blockByNumber" do
    {200, %{"result" => _ret}} = rpc("eth_get_blockByNumber", [0, false])
    {200, %{"result" => _ret}} = rpc("eth_get_blockByNumber", [1, false])
    {404, %{"result" => _ret}} = rpc("eth_get_blockByNumber", [150, false])
    {200, %{"result" => _ret}} = rpc("eth_get_blockByNumber", ["earliest", false])
    {200, %{"result" => _ret}} = rpc("eth_get_blockByNumber", ["latest", false])
  end

  test "transaction ordering" do
    [from, to] = Diode.wallets() |> Enum.reverse() |> Enum.take(2)

    before = Chain.peakState()

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
          "gas_price" => 0
        })
      end)

    # Ordering in wrong nonce order
    txs = [tx2, tx1, tx3]

    Enum.each(txs, fn tx ->
      rpc("eth_sendRawTransaction", [to_rlp(tx)])
    end)

    Worker.set_mode(:poll)
    Worker.work()

    # Checking values now after transfer
    result = Chain.peakState()
    from_acc2 = State.ensure_account(result, from)
    to_acc2 = State.ensure_account(result, to)

    assert Account.nonce(from_acc2) == nonce + length(txs)
    assert Account.balance(from_acc) - Account.balance(from_acc2) == 1000 * length(txs)
    assert Account.balance(to_acc2) - Account.balance(to_acc) == 1000 * length(txs)
  end

  defp to_rlp(tx) do
    tx |> Transaction.to_rlp() |> Rlp.encode!() |> Base16.encode()
  end

  # %{id: id, method: "trace_replayBlockTransactions", params: [^block_quantity, ["trace"]]} ->
  #   {:ok,
  #    [
  #      %{
  #        id: id,
  #        jsonrpc: "2.0",
  #        result: [
  #          %{
  #            "output" => "0x",
  #            "stateDiff" => nil,
  #            "trace" => [
  #              %{
  #                "action" => %{
  #                  "callType" => "call",
  #                  "from" => from_address_hash,
  #                  "gas" => "0x475ec8",
  #                  "input" =>
  #                    "0x10855269000000000000000000000000862d67cb0773ee3f8ce7ea89b328ffea861ab3ef",
  #                  "to" => to_address_hash,
  #                  "value" => "0x0"
  #                },
  #                "result" => %{"gas_used" => "0x6c7a", "output" => "0x"},
  #                "subtraces" => 0,
  #                "traceAddress" => [],
  #                "type" => "call"
  #              }
  #            ],
  #            "transactionHash" => transaction_hash,
  #            "vmTrace" => nil
  #          }
  #        ]
  #      }
  #    ]}

  def rpc(method, params) do
    Rpc.handle_jsonrpc(%{"method" => method, "params" => params, "id" => 1})
  end
end
