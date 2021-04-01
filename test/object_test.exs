# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule TicketTest do
  use ExUnit.Case
  alias Object.Server

  # Testing forward compatibility of server tickets

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
end
