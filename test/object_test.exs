# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule TicketTest do
  use ExUnit.Case
  alias Object.Server

  # Testing forward compatibility of server tickets

  test "forward compatibility" do
    correct =
      Server.new("host", 1, 2)
      |> Object.Server.sign(Wallet.privkey!(Diode.miner()))

    assert Server.host(correct) == "host"
    assert Server.edge_port(correct) == 1
    assert Server.peer_port(correct) == 2
    assert Server.key(correct) == Wallet.address!(Diode.miner())

    extended =
      {:server, "host", 1, 2, "a", "b", "c", "signature"}
      |> Object.Server.sign(Wallet.privkey!(Diode.miner()))

    assert Server.host(extended) == "host"
    assert Server.edge_port(extended) == 1
    assert Server.peer_port(extended) == 2
    assert Server.key(extended) == Wallet.address!(Diode.miner())
  end
end
