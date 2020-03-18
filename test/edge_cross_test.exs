# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule EdgeCrossTest do
  use ExUnit.Case, async: false

  @port_num 3000
  @port_bin Rlpx.num2bin(@port_num)

  setup do
    TicketStore.clear()
    :persistent_term.put(:no_tickets, false)
  end

  setup_all do
    Diode.ticket_grace(4096)
    :persistent_term.put(:no_tickets, false)

    on_exit(fn ->
      IO.puts("Killing clients")

      if Process.whereis(:client_1) != nil do
        {:ok, _} = Edge1Client.call(:client_1, :quit)
      end

      if Process.whereis(:client_2) != nil do
        {:ok, _} = Edge2Client.call(:client_2, :quit)
      end
    end)
  end

  test "cross v1/v2 port communication " do
    IO.puts("Starting clients")
    Edge1Client.ensure_client(:client_1, 1)
    Edge2Client.ensure_client(:client_2, 2)

    # Connecting to "right" port id
    client2id = Wallet.address!(Edge2Client.clientid(2))

    assert Edge1Client.csend(:client_1, ["portopen", client2id, @port_num]) == {:ok, :ok}
    {:ok, [req2, ["portopen", @port_bin, ref1, access_id]]} = Edge2Client.crecv(:client_2)
    assert access_id == Wallet.address!(Edge1Client.clientid(1))

    assert Edge2Client.csend(:client_2, ["response", ref1, "ok"], req2) == {:ok, :ok}
    {:ok, ["response", "portopen", "ok", ref2]} = Edge1Client.crecv(:client_1)
    assert ref1 == ref2

    for n <- 1..50 do
      check_counters()

      # Sending traffic
      msg = String.duplicate("ping from 2!", n * n)
      assert Edge2Client.rpc(:client_2, ["portsend", ref1, msg]) == ["ok"]
      assert {:ok, ["portsend", ^ref1, ^msg]} = Edge1Client.crecv(:client_1)

      check_counters()

      # Both ways
      msg = String.duplicate("ping from 1!", n * n)
      assert Edge1Client.rpc(:client_1, ["portsend", ref1, msg]) == ["response", "portsend", "ok"]
      assert {:ok, [_req, ["portsend", ^ref1, ^msg]]} = Edge2Client.crecv(:client_2)
    end

    check_counters()
    # Closing port
    assert Edge1Client.rpc(:client_1, ["portclose", ref1]) == ["response", "portclose", "ok"]
    assert {:ok, [_req, ["portclose", ^ref1]]} = Edge2Client.crecv(:client_2)

    # Sending to closed port
    assert Edge2Client.rpc(:client_2, ["portsend", ref1, "ping from 2!"]) == [
             "port does not exist"
           ]

    assert Edge1Client.rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == [
             "error",
             "portsend",
             "port does not exist"
           ]
  end

  defp check_counters() do
    # Checking counters
    Edge2Client.rpc(:client_2, ["bytes"])
    {:ok, bytes} = Edge2Client.call(:client_2, :bytes)
    assert Edge2Client.rpc(:client_2, ["bytes"]) == [bytes |> Edge2Client.to_sbin()]

    Edge1Client.rpc(:client_1, ["bytes"])
    {:ok, bytes} = Edge1Client.call(:client_1, :bytes)
    assert Edge1Client.rpc(:client_1, ["bytes"]) == ["response", "bytes", bytes]
  end
end
