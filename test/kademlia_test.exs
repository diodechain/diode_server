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
  @network_size 6
  setup_all do
    reset()
    :io.format("Kademlia starting clones~n")
    start_clones(@network_size)

    on_exit(fn ->
      kill_clones()
    end)
  end

  defp connect_clones(range) do
    for n <- range do
      pid = Server.ensure_node_connection(PeerHandler, Wallet.new(), "localhost", peer_port(n))
      assert GenServer.call(pid, :ping) == :pong
    end
  end

  test "connect" do
    wait_for(
      fn -> Server.get_connections(PeerHandler) == %{} end,
      "connections to drain"
    )

    conns = Server.get_connections(PeerHandler)
    assert map_size(conns) == 0
    connect_clones(1..@network_size)
    assert map_size(Server.get_connections(PeerHandler)) == @network_size
    assert KBuckets.size(Kademlia.network()) == @network_size + 1
  end

  test "send/receive" do
    connect_clones(1..@network_size)

    values = Enum.map(1..100, fn idx -> {"#{idx}", "value_#{idx}"} end)
    before = Process.list()

    :io.format("Kademlia store")

    for {key, value} <- values do
      :io.format(" #{key}")
      Kademlia.store(key, value)
    end

    :io.format("~n")

    :io.format("Kademlia find_value ")

    for {key, value} <- values do
      :io.format("#{key} ")
      assert Kademlia.find_value(key) == value
    end

    for {key, _value} <- values do
      :io.format("not_#{key} ")
      assert Kademlia.find_value("not_#{key}") == nil
    end

    :io.format("~n")

    assert length(before) <= length(Process.list())
  end

  test "redistribute" do
    connect_clones(1..@network_size)

    values = Enum.map(1..100, fn idx -> {"re_#{idx}", "value_#{idx}"} end)

    :io.format("Kademlia store")

    for {key, value} <- values do
      :io.format(" #{key}")
      Kademlia.store(key, value)
    end

    :io.format("~n")

    add_clone(@network_size + 1)
    wait_clones(@network_size + 1, 60)
    connect_clones(1..(@network_size + 1))
    assert KBuckets.size(Kademlia.network()) == @network_size + 2

    for {key, value} <- values do
      :io.format("Kademlia find_value #{key}~n")
      assert Kademlia.find_value(key) == value
    end
  end

  test "failed server" do
    values = Enum.map(1..50, fn idx -> {"#{idx}", "value_#{idx}"} end)

    :io.format("Kademlia store")

    for {key, value} <- values do
      :io.format(" #{key}")
      Kademlia.store(key, value)
    end

    :io.format("~n")

    freeze_clone(1)

    :io.format("Kademlia find_value")

    for {key, value} <- values do
      :io.format(" #{key}")
      assert Kademlia.find_value(key) == value
    end

    :io.format("~n")

    unfreeze_clone(1)
  end
end
