# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule KademliaTest do
  use ExUnit.Case, async: false
  alias Network.Server, as: Server
  alias Network.PeerHandler, as: PeerHandler
  import TestHelper

  # Need bigger number to have a not connected network
  # 30
  @network_size 2
  setup_all do
    reset()
    start_clones(@network_size)

    on_exit(fn ->
      kill_clones()
    end)
  end

  test "connect" do
    wait_for(
      fn -> Server.get_connections(PeerHandler) == %{} end,
      "connections to drain"
    )

    conns = Server.get_connections(PeerHandler)
    assert map_size(conns) == 0

    for n <- 1..@network_size do
      pid = Server.ensure_node_connection(PeerHandler, Wallet.new(), "localhost", peer_port(n))
      assert GenServer.call(pid, :ping) == :pong
      assert map_size(Server.get_connections(PeerHandler)) == n
    end

    # network = GenServer.call(Kademlia, :get_network)
    # :io.format("~p~n", [KBuckets.size(network)])
    # assert KBuckets.size(network) == n + 1
  end

  test "send/receive" do
    values = Enum.map(1..100, fn idx -> {"#{idx}", "value_#{idx}"} end)

    for {key, value} <- values do
      Kademlia.store(key, value)
    end

    for {key, value} <- values do
      assert Kademlia.find_value(key) == value
    end

    for {key, _value} <- values do
      assert Kademlia.find_value("not_#{key}") == nil
    end
  end
end
