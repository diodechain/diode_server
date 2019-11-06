# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule PeerTest do
  use ExUnit.Case, async: false
  alias Chain.Block, as: Block
  alias Network.Server, as: Server
  alias Network.PeerHandler, as: PeerHandler

  import TestHelper

  setup_all do
    reset()
    start_clones(1)

    on_exit(fn ->
      kill_clones()
    end)
  end

  test "sync" do
    if Diode.travis_mode?() do
      :ok
    else
      testSync()
    end
  end

  def testSync() do
    wait_for(
      fn -> Network.Server.get_connections(PeerHandler) == %{} end,
      "connections to drain"
    )

    # The Genesis Block should be the same
    assert Block.hash(Chain.block(0)) == rpc(1, "eth_getBlockByNumber", "0,false")["hash"]

    # There should be only one block on the new clone
    assert 1 == :binary.decode_unsigned(rpc(1, "eth_blockNumber"))

    # Building test blocks for syncing
    assert Chain.peak() == 1
    for _ <- 1..10, do: Chain.Worker.work()
    assert Chain.peak() == 11

    # Creating peer connection
    pid = Server.ensure_node_connection(PeerHandler, nil, "localhost", kademliaPort(1))
    assert GenServer.call(pid, :ping) == :pong

    # Waiting for the connection to settle
    wait_for(
      fn -> map_size(Network.Server.get_connections(PeerHandler)) == 1 end,
      "clone connection",
      30
    )

    [_clone] = Map.values(Network.Server.get_connections(PeerHandler))

    # This shall force trigger a publish of all blocks to the clone
    Chain.Worker.work()

    wait_for(
      fn -> Chain.peak() == :binary.decode_unsigned(rpc(1, "eth_blockNumber")) end,
      "block sync",
      30
    )
  end

  defp rpc(num, method, params \\ "") do
    {:ok, {_head, _opt, body}} =
      :httpc.request(
        :post,
        {'http://localhost:#{rpcPort(num)}', [], 'application/json',
         '{"id":1, "method":"#{method}", "params":[#{params}]}'},
        [timeout: 5000],
        []
      )

    Json.decode!(body)
    |> Map.get("result")
  end
end
