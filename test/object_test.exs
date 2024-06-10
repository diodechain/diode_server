# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule ObjectTest do
  use ExUnit.Case
  alias Object.Server

  # Testing forward compatibility of server objects

  test "forward/backward compatibility" do
    classic =
      {:server, "host", 1, 2, "a", "signature"}
      |> Object.Server.sign(Wallet.privkey!(Diode.miner()))

    assert Server.host(classic) == "host"
    assert Server.edge_port(classic) == 1
    assert Server.peer_port(classic) == 2
    assert Server.key(classic) == Wallet.address!(Diode.miner())

    extended =
      {:server, "host", 1, 2, "a", "b", "c", "signature"}
      |> Object.Server.sign(Wallet.privkey!(Diode.miner()))

    assert Server.host(extended) == "host"
    assert Server.edge_port(extended) == 1
    assert Server.peer_port(extended) == 2
    assert Server.key(extended) == Wallet.address!(Diode.miner())
  end

  test "encode/decode compat" do
    objs =
      for idx <- 1..100 do
        Object.Data.new(Chain.peak(), "name_#{idx}", "value", Wallet.privkey!(Wallet.new()))
      end

    for object <- objs do
      key = Object.key(object)

      encoded = Object.encode!(object)
      decoded = Object.decode!(encoded)

      assert decoded == object
      assert Object.key(decoded) == key

      Model.KademliaSql.put_object(Kademlia.hash(key), encoded)

      loaded =
        Model.KademliaSql.object(Kademlia.hash(key))
        |> Object.decode!()

      assert Object.key(loaded) == key
    end

    <<max::integer-size(256)>> = String.duplicate(<<255>>, 32)

    map =
      Model.KademliaSql.objects(0, max)
      |> Map.new()

    for object <- objs do
      key = Kademlia.hash(Object.key(object))
      assert Object.decode!(Map.get(map, key)) == object
    end
  end
end
