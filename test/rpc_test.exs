defmodule RpcTest do
  use ExUnit.Case, async: true
  alias Network.Rpc

  test "trace_replayBlockTransactions" do
    {200, %{"result" => ret}} = rpc("trace_replayBlockTransactions", ["earliest", ["trace"]])
    # :io.format("ret: ~p~n", [ret])
    ret
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
  #                "result" => %{"gasUsed" => "0x6c7a", "output" => "0x"},
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
