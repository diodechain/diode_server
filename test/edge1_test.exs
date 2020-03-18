# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Edge1Test do
  use ExUnit.Case, async: false
  alias Network.Server, as: Server
  alias Network.EdgeV1, as: EdgeHandler
  alias Object.Ticket, as: Ticket
  import Ticket
  import Edge1Client

  @ticket_grace 4096

  setup do
    TicketStore.clear()
    :persistent_term.put(:no_tickets, false)
    ensure_clients()
  end

  setup_all do
    IO.puts("Starting clients")
    Diode.ticket_grace(@ticket_grace)
    :persistent_term.put(:no_tickets, false)
    ensure_clients()

    on_exit(fn ->
      IO.puts("Killing clients")
      ensure_clients()
      {:ok, _} = call(:client_1, :quit)
      {:ok, _} = call(:client_2, :quit)
    end)
  end

  test "connect" do
    # Test that clients are connected
    assert call(:client_1, :ping) == {:ok, :pong}
    assert call(:client_2, :ping) == {:ok, :pong}
    conns = Server.get_connections(EdgeHandler)
    assert map_size(conns) == 2

    # Test that clients are connected to this node
    {:ok, peer_1} = call(:client_1, :peerid)
    {:ok, peer_2} = call(:client_2, :peerid)
    assert Wallet.equal?(Diode.miner(), peer_1)
    assert Wallet.equal?(Diode.miner(), peer_2)

    # Test that clients connected match the test file identities
    [id1, id2] = Map.keys(conns)

    if Wallet.equal?(id1, clientid(1)) do
      assert Wallet.equal?(id2, clientid(2))
    else
      assert Wallet.equal?(id1, clientid(2))
      assert Wallet.equal?(id2, clientid(1))
    end

    # Test byte counter matches
    assert call(:client_1, :bytes) == {:ok, 102}
    assert call(:client_2, :bytes) == {:ok, 102}
    assert rpc(:client_1, ["bytes"]) == ["response", "bytes", 102]
    assert rpc(:client_2, ["bytes"]) == ["response", "bytes", 102]
  end

  test "getblock" do
    assert rpc(:client_1, ["getblockpeak"]) == ["response", "getblockpeak", Chain.peak()]
  end

  test "getaccount" do
    ["error", "getaccount", "account does not exist"] =
      rpc(:client_1, ["getaccount", Chain.peak(), "01234567890123456789"])

    {addr, acc} = hd(Chain.GenesisFactory.genesis_accounts())

    ["response", "getaccount", ret, _proof] = rpc(:client_1, ["getaccount", Chain.peak(), addr])

    assert ret["code"] == Chain.Account.codehash(acc)
    assert ret["balance"] == acc.balance
  end

  test "getaccountvalue" do
    ["error", "getaccountvalue", "account does not exist"] =
      rpc(:client_1, ["getaccountvalue", Chain.peak(), "01234567890123456789", 0])

    {addr, _balance} = hd(Chain.GenesisFactory.genesis_accounts())

    ["response", "getaccountvalue", ret] =
      rpc(:client_1, ["getaccountvalue", Chain.peak(), addr, 0])

    # Should be empty
    assert length(ret) == 2
  end

  test "ticket" do
    :persistent_term.put(:no_tickets, true)
    {:ok, _} = call(:client_1, :quit)
    {:ok, _} = call(:client_2, :quit)
    TicketStore.clear()
    ensure_clients()

    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak(),
        fleet_contract: <<0::unsigned-size(160)>>
      )
      |> Ticket.device_sign(clientkey(1))

    # The first ticket submission should work
    assert rpc(:client_1, [
             "ticket",
             Ticket.block_number(tck),
             Ticket.fleet_contract(tck),
             Ticket.total_connections(tck),
             Ticket.total_bytes(tck),
             Ticket.local_address(tck),
             Ticket.device_signature(tck)
           ]) ==
             [
               "response",
               "ticket",
               "thanks!",
               0
             ]

    # Submitting a second ticket with the same count should fail
    assert rpc(:client_1, [
             "ticket",
             Ticket.block_number(tck),
             Ticket.fleet_contract(tck),
             Ticket.total_connections(tck),
             Ticket.total_bytes(tck),
             Ticket.local_address(tck),
             Ticket.device_signature(tck)
           ]) ==
             [
               "response",
               "ticket",
               "too_low",
               Ticket.block_hash(tck),
               Ticket.total_connections(tck),
               Ticket.total_bytes(tck),
               Ticket.local_address(tck),
               Ticket.device_signature(tck)
             ]

    # Waiting for Kademlia Debouncer to write the object to the file
    Process.sleep(1000)
    ["response", "getobject", loc2] = rpc(:client_1, ["getobject", Wallet.address!(clientid(1))])

    loc2 = Object.decode_list!(loc2)
    assert Ticket.device_blob(tck) == Ticket.device_blob(loc2)

    assert Secp256k1.verify(
             Diode.miner(),
             Ticket.server_blob(loc2),
             Ticket.server_signature(loc2),
             :kec
           ) == true

    public = Secp256k1.recover!(Ticket.server_signature(loc2), Ticket.server_blob(loc2), :kec)
    id = Wallet.from_pubkey(public) |> Wallet.address!()

    assert Wallet.address!(Diode.miner()) == Wallet.address!(Wallet.from_pubkey(public))
    assert id == Wallet.address!(Diode.miner())

    obj = Diode.self()
    assert(Object.key(obj) == id)
    enc = Json.encode!(Object.encode_list!(obj))
    assert obj == Object.decode_list!(Json.decode!(enc))

    # Getnode
    ["response", "getnode", node] = rpc(:client_1, ["getnode", id])
    node = Object.decode_list!(node)
    assert(Object.key(node) == id)

    # Testing ticket integrity
    Model.TicketSql.tickets_raw()
    |> Enum.each(fn {dev, fleet, epoch, tck} ->
      assert Object.Ticket.device_address(tck) == dev
      assert Object.Ticket.epoch(tck) == epoch
      assert Object.Ticket.fleet_contract(tck) == fleet
    end)

    # Testing disconnect
    ["error", 401, "bad input"] = rpc(:client_1, ["garbage", String.pad_leading("", 1024 * 3)])

    ["goodbye", "ticket expected", "you might get blacklisted"] =
      rpc(:client_1, ["garbage", String.pad_leading("", 1024)])

    # {:ok, ["goodbye", "ticket expected", "you might get blacklisted"]} = crecv(:client_1)
    {:error, :timeout} = crecv(:client_1)
  end

  test "port" do
    check_counters()
    # Checking wrong port_id usage
    assert rpc(:client_1, ["portopen", "wrongid", 3000]) == [
             "error",
             "portopen",
             "invalid address"
           ]

    assert rpc(:client_1, ["portopen", "12345678901234567890", 3000]) == [
             "error",
             "portopen",
             "not found"
           ]

    assert rpc(:client_1, ["portopen", Wallet.address!(clientid(1)), 3000]) == [
             "error",
             "portopen",
             "can't connect to yourself"
           ]

    check_counters()
    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, 3000]) == {:ok, :ok}
    {:ok, ["portopen", 3000, ref1, access_id]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    assert csend(:client_2, ["response", "portopen", ref1, "ok"]) == {:ok, :ok}
    {:ok, ["response", "portopen", "ok", ref2]} = crecv(:client_1)
    assert ref1 == ref2

    for n <- 1..50 do
      check_counters()

      # Sending traffic
      msg = String.duplicate("ping from 2!", n * n)
      assert rpc(:client_2, ["portsend", ref1, msg]) == ["response", "portsend", "ok"]
      assert crecv(:client_1) == {:ok, ["portsend", ref1, msg]}

      check_counters()

      # Both ways
      msg = String.duplicate("ping from 1!", n * n)
      assert rpc(:client_1, ["portsend", ref1, msg]) == ["response", "portsend", "ok"]
      assert crecv(:client_2) == {:ok, ["portsend", ref1, msg]}
    end

    check_counters()
    # Closing port
    assert rpc(:client_1, ["portclose", ref1]) == ["response", "portclose", "ok"]
    assert crecv(:client_2) == {:ok, ["portclose", ref1]}

    # Sending to closed port
    assert rpc(:client_2, ["portsend", ref1, "ping from 2!"]) == [
             "error",
             "portsend",
             "port does not exist"
           ]

    assert rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == [
             "error",
             "portsend",
             "port does not exist"
           ]
  end

  test "porthalfopen_a" do
    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, 3000]) == {:ok, :ok}
    {:ok, ["portopen", 3000, ref1, access_id]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    kill(:client_1)

    assert csend(:client_2, ["response", "portopen", ref1, "ok"]) == {:ok, :ok}
    {:ok, ["portclose", ref2]} = crecv(:client_2)
    assert ref1 == ref2
  end

  test "porthalfopen_b" do
    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, 3000]) == {:ok, :ok}

    {:ok, ["portopen", 3000, ref1, access_id]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    kill(:client_2)

    {:ok, ["error", "portopen", _reason, ref2]} = crecv(:client_1)
    assert ref1 == ref2
  end

  test "port2x" do
    # First connection
    # Process.sleep(1000)
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, 3000]) == {:ok, :ok}
    Process.sleep(1000)
    assert call(:client_1, :peek) == {:ok, :empty}

    {:ok, ["portopen", 3000, ref1, access_id]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    assert csend(:client_2, ["response", "portopen", ref1, "ok"]) == {:ok, :ok}
    {:ok, ["response", "portopen", "ok", ref2]} = crecv(:client_1)
    assert ref1 == ref2

    # Second connection
    assert csend(:client_1, ["portopen", client2id, 3000]) == {:ok, :ok}
    {:ok, ["portopen", 3000, ref3, access_id]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    assert csend(:client_2, ["response", "portopen", ref3, "ok"]) == {:ok, :ok}
    {:ok, ["response", "portopen", "ok", ref4]} = crecv(:client_1)
    assert ref3 == ref4
    assert ref1 != ref3

    for _ <- 1..10 do
      # Sending traffic
      assert rpc(:client_2, ["portsend", ref1, "ping from 2 on 1!"]) == [
               "response",
               "portsend",
               "ok"
             ]

      assert crecv(:client_1) == {:ok, ["portsend", ref1, "ping from 2 on 1!"]}

      assert rpc(:client_2, ["portsend", ref4, "ping from 2 on 2!"]) == [
               "response",
               "portsend",
               "ok"
             ]

      assert crecv(:client_1) == {:ok, ["portsend", ref4, "ping from 2 on 2!"]}
    end

    # Closing port1
    assert rpc(:client_1, ["portclose", ref1]) == ["response", "portclose", "ok"]
    assert crecv(:client_2) == {:ok, ["portclose", ref1]}
    # Closing port2
    assert rpc(:client_1, ["portclose", ref4]) == ["response", "portclose", "ok"]
    assert crecv(:client_2) == {:ok, ["portclose", ref4]}
  end

  test "sharedport flags" do
    # Connecting with wrong flags
    client2id = Wallet.address!(clientid(2))
    ["error", "portopen", "invalid flags"] = rpc(:client_1, ["portopen", client2id, 3000, "s"])
  end

  test "sharedport" do
    # Connecting to port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, 3000, "rws"]) == {:ok, :ok}
    {:ok, ["portopen", 3000, ref1, access_id]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    # 'Device' accepts connection
    assert csend(:client_2, ["response", "portopen", ref1, "ok"]) == {:ok, :ok}
    {:ok, ["response", "portopen", "ok", ref2]} = crecv(:client_1)
    assert ref1 == ref2

    # Connecting same client to same port again
    ["response", "portopen", "ok", ref3] = rpc(:client_1, ["portopen", client2id, 3000, "rws"])
    assert ref3 != ref2

    for _ <- 1..10 do
      # Sending traffic
      assert rpc(:client_2, ["portsend", ref1, "ping from 2!"]) == ["response", "portsend", "ok"]
      assert crecv(:client_1) == {:ok, ["portsend", ref3, "ping from 2!"]}
      assert crecv(:client_1) == {:ok, ["portsend", ref1, "ping from 2!"]}
    end

    # Closing port ref1
    assert rpc(:client_1, ["portclose", ref1]) == ["response", "portclose", "ok"]

    # Other port ref3 still working
    assert rpc(:client_1, ["portsend", ref3, "ping from 3!"]) == ["response", "portsend", "ok"]
    assert crecv(:client_2) == {:ok, ["portsend", ref1, "ping from 3!"]}

    # Sending to closed port
    assert rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == [
             "error",
             "portsend",
             "port does not exist"
           ]

    # Closing port ref3
    assert rpc(:client_1, ["portclose", ref3]) == ["response", "portclose", "ok"]
    assert crecv(:client_2) == {:ok, ["portclose", ref1]}
  end

  test "doubleconn" do
    old_pid = Process.whereis(:client_1)
    assert true == Process.alive?(old_pid)
    new_client = client(1)

    assert call(new_client, :ping) == {:ok, :pong}

    Process.sleep(1000)
    assert false == Process.alive?(old_pid)
  end

  test "getblockquick" do
    for _ <- 1..50, do: Chain.Worker.work()
    peak = Chain.peak()

    # Test blockquick with gap
    window_size = 10
    ["response", "getblockquick", headers] = rpc(:client_1, ["getblockquick", 30, window_size])

    Enum.reduce(headers, peak - 9, fn [head, _miner], num ->
      assert head["number"] == num
      num + 1
    end)

    assert length(headers) == window_size

    # Test blockquick with gap
    window_size = 20
    ["response", "getblockquick", headers] = rpc(:client_1, ["getblockquick", 30, window_size])

    Enum.reduce(headers, peak - 19, fn [head, _miner], num ->
      assert head["number"] == num
      num + 1
    end)

    assert length(headers) == window_size

    # Test blockquick without gap
    window_size = 20

    ["response", "getblockquick", headers] =
      rpc(:client_1, ["getblockquick", peak - 10, window_size])

    Enum.reduce(headers, peak - 9, fn [head, _miner], num ->
      assert head["number"] == num
      num + 1
    end)

    assert length(headers) == 10
  end

  defp check_counters() do
    # Checking counters
    {:ok, bytes} = call(:client_2, :bytes)
    assert rpc(:client_2, ["bytes"]) == ["response", "bytes", bytes]

    {:ok, bytes} = call(:client_1, :bytes)
    assert rpc(:client_1, ["bytes"]) == ["response", "bytes", bytes]
  end

  defp kill(atom) do
    case Process.whereis(atom) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        wait_for_process(atom)
    end
  end

  defp wait_for_process(atom) do
    case Process.whereis(atom) do
      nil ->
        :ok

      _pid ->
        Process.sleep(100)
        wait_for_process(atom)
    end
  end
end
