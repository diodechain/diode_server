# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Edge2Test do
  use ExUnit.Case, async: false
  alias Network.Server, as: Server
  alias Network.EdgeV2, as: EdgeHandler
  alias Object.Ticket, as: Ticket
  alias Object.Channel, as: Channel
  import Ticket
  import Channel
  import Edge2Client

  @ticket_grace 4096
  @port Rlpx.num2bin(3000)

  setup do
    TicketStore.clear()
    Model.KademliaSql.clear()
    :persistent_term.put(:no_tickets, false)
    ensure_clients()
  end

  setup_all do
    IO.puts("Starting clients")
    Diode.ticket_grace(@ticket_grace)
    :persistent_term.put(:no_tickets, false)
    Process.put(:req_id, 0)
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
    assert call(:client_1, :bytes) == {:ok, 75}
    assert call(:client_2, :bytes) == {:ok, 75}
    assert rpc(:client_1, ["bytes"]) == [75 |> to_sbin()]
    assert rpc(:client_2, ["bytes"]) == [75 |> to_sbin()]
  end

  test "getblock" do
    assert rpc(:client_1, ["getblockpeak"]) == [Chain.peak() |> to_bin()]
  end

  test "getaccount" do
    ["account does not exist"] =
      rpc(:client_1, ["getaccount", Chain.peak(), "01234567890123456789"])

    ["account does not exist"] =
      rpc(:client_1, ["getaccount", Chain.peak(), Wallet.address!(Wallet.new())])

    ["account does not exist"] =
      rpc(:client_1, ["getaccountroots", Chain.peak(), Wallet.address!(Wallet.new())])

    {addr, acc} = hd(Chain.GenesisFactory.genesis_accounts())

    [ret, _proof] = rpc(:client_1, ["getaccount", Chain.peak(), addr])

    ret = Rlpx.list2map(ret)

    assert ret["code"] == Chain.Account.codehash(acc)
    assert to_num(ret["balance"]) == acc.balance
  end

  test "getaccountvalue" do
    ["account does not exist"] =
      rpc(:client_1, ["getaccountvalue", Chain.peak(), "01234567890123456789", 0])

    {addr, _balance} = hd(Chain.GenesisFactory.genesis_accounts())

    [ret] = rpc(:client_1, ["getaccountvalue", Chain.peak(), addr, 0])

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
        fleet_contract: Diode.fleet_address()
      )
      |> Ticket.device_sign(clientkey(1))

    # The first ticket submission should work
    assert rpc(:client_1, [
             "ticket",
             Ticket.block_number(tck) |> to_bin(),
             Ticket.fleet_contract(tck),
             Ticket.total_connections(tck) |> to_bin(),
             Ticket.total_bytes(tck) |> to_bin(),
             Ticket.local_address(tck),
             Ticket.device_signature(tck)
           ]) ==
             [
               "thanks!",
               ""
             ]

    # Submitting a second ticket with the same count should fail
    assert rpc(:client_1, [
             "ticket",
             Ticket.block_number(tck) |> to_bin(),
             Ticket.fleet_contract(tck),
             Ticket.total_connections(tck),
             Ticket.total_bytes(tck),
             Ticket.local_address(tck),
             Ticket.device_signature(tck)
           ]) ==
             [
               "too_low",
               Ticket.block_hash(tck),
               Ticket.total_connections(tck) |> to_bin(),
               Ticket.total_bytes(tck) |> to_bin(),
               Ticket.local_address(tck),
               Ticket.device_signature(tck)
             ]

    # Waiting for Kademlia Debouncer to write the object to the file
    Process.sleep(1000)

    #   Record.defrecord(:ticket,
    #   server_id: nil,
    #   block_number: nil,
    #   fleet_contract: nil,
    #   total_connections: nil,
    #   total_bytes: nil,
    #   local_address: nil,
    #   device_signature: nil,
    #   server_signature: nil
    # )
    [ticket] = rpc(:client_1, ["getobject", Wallet.address!(clientid(1))])

    loc2 = Object.decode_rlp_list!(ticket)
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
    enc = Rlp.encode!(Object.encode_list!(obj))
    assert obj == Object.decode_rlp_list!(Rlp.decode!(enc))

    # Getnode
    [node] = rpc(:client_1, ["getnode", id])
    node = Object.decode_rlp_list!(node)
    assert(Object.key(node) == id)

    # Testing ticket integrity
    Model.TicketSql.tickets_raw()
    |> Enum.each(fn {dev, fleet, epoch, tck} ->
      assert Object.Ticket.device_address(tck) == dev
      assert Object.Ticket.epoch(tck) == epoch
      assert Object.Ticket.fleet_contract(tck) == fleet
    end)

    # Testing disconnect
    [_req, "bad input"] = rpc(:client_1, ["garbage", String.pad_leading("", 1024 * 4)])

    csend(:client_1, "garbage", String.pad_leading("", 1024))
    {:ok, [_req, ["goodbye", "ticket expected", "you might get blacklisted"]]} = crecv(:client_1)
    {:error, :timeout} = crecv(:client_1)
  end

  test "port" do
    check_counters()
    # Checking wrong port_id usage
    assert rpc(:client_1, ["portopen", "wrongid", @port]) == ["invalid address"]
    assert rpc(:client_1, ["portopen", "12345678901234567890", @port]) == ["not found"]

    assert rpc(:client_1, ["portopen", Wallet.address!(clientid(1)), @port]) == [
             "can't connect to yourself"
           ]

    check_counters()
    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    req1 = req_id()
    assert csend(:client_1, ["portopen", client2id, @port], req1) == {:ok, :ok}
    {:ok, [req2, ["portopen", @port, ref1, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    assert csend(:client_2, ["response", ref1, "ok"], req2) == {:ok, :ok}
    {:ok, [_req, ["response", "ok", ref2]]} = crecv(:client_1, req1)
    assert ref1 == ref2

    for n <- 1..50 do
      check_counters()

      # Sending traffic
      msg = String.duplicate("ping from 2!", n * n)
      assert rpc(:client_2, ["portsend", ref1, msg]) == ["ok"]
      assert {:ok, [_req, ["portsend", ^ref1, ^msg]]} = crecv(:client_1)

      check_counters()

      # Both ways
      msg = String.duplicate("ping from 1!", n * n)
      assert rpc(:client_1, ["portsend", ref1, msg]) == ["ok"]
      assert {:ok, [_req, ["portsend", ^ref1, ^msg]]} = crecv(:client_2)
    end

    check_counters()
    # Closing port
    assert rpc(:client_1, ["portclose", ref1]) == ["ok"]
    assert {:ok, [_req, ["portclose", ^ref1]]} = crecv(:client_2)

    # Sending to closed port
    assert rpc(:client_2, ["portsend", ref1, "ping from 2!"]) == [
             "port does not exist"
           ]

    assert rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == [
             "port does not exist"
           ]
  end

  test "channel" do
    # Checking non existing channel
    assert rpc(:client_1, ["portopen", "12345678901234567890123456789012", @port]) == [
             "not found"
           ]

    ch =
      channel(
        server_id: Wallet.address!(Diode.miner()),
        block_number: Chain.peak(),
        fleet_contract: Diode.fleet_address(),
        type: "broadcast",
        name: "testchannel"
      )
      |> Channel.sign(clientkey(1))

    port = Object.Channel.key(ch)

    [channel] =
      rpc(:client_1, [
        "channel",
        Channel.block_number(ch),
        Channel.fleet_contract(ch),
        Channel.type(ch),
        Channel.name(ch),
        Channel.params(ch),
        Channel.signature(ch)
      ])

    assert Object.decode_rlp_list!(channel) == ch
    assert ["ok", ref1] = rpc(:client_1, ["portopen", port, @port])
    ch2 = Channel.sign(ch, clientkey(2))

    [channel2] =
      rpc(:client_2, [
        "channel",
        Channel.block_number(ch2),
        Channel.fleet_contract(ch2),
        Channel.type(ch2),
        Channel.name(ch2),
        Channel.params(ch2),
        Channel.signature(ch2)
      ])

    # Asserting that the retrieved channel is actually the one openend by client1
    assert Object.decode_rlp_list!(channel2) == ch

    assert ["ok", ref2] = rpc(:client_2, ["portopen", port, @port])

    for n <- 1..50 do
      # Sending traffic
      msg = String.duplicate("ping from 2!", n * n)
      assert rpc(:client_2, ["portsend", ref2, msg]) == ["ok"]
      assert {:ok, [_req, ["portsend", ^ref1, ^msg]]} = crecv(:client_1)

      # Both ways
      msg = String.duplicate("ping from 1!", n * n)
      assert rpc(:client_1, ["portsend", ref1, msg]) == ["ok"]
      assert {:ok, [_req, ["portsend", ^ref2, ^msg]]} = crecv(:client_2)
    end

    # Closing port
    # Channels always stay open for all other participants
    # So client_1 closing does leave the port open for client_2
    assert rpc(:client_1, ["portclose", ref1]) == ["ok"]

    # Sending to closed port
    assert rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == ["port does not exist"]
    assert rpc(:client_2, ["portsend", ref2, "ping from 2!"]) == ["ok"]
  end

  test "channel-mailbox" do
    ch =
      channel(
        server_id: Wallet.address!(Diode.miner()),
        block_number: Chain.peak(),
        fleet_contract: Diode.fleet_address(),
        type: "mailbox",
        name: "testchannel"
      )
      |> Channel.sign(clientkey(1))

    port = Object.Channel.key(ch)

    [channel] =
      rpc(:client_1, [
        "channel",
        Channel.block_number(ch),
        Channel.fleet_contract(ch),
        Channel.type(ch),
        Channel.name(ch),
        Channel.params(ch),
        Channel.signature(ch)
      ])

    assert Object.decode_rlp_list!(channel) == ch
    assert ["ok", ref1] = rpc(:client_1, ["portopen", port, @port])

    for n <- 1..50 do
      assert rpc(:client_1, ["portsend", ref1, "ping #{n}"]) == ["ok"]
    end

    assert rpc(:client_1, ["portclose", ref1]) == ["ok"]
    assert ["ok", ref2] = rpc(:client_2, ["portopen", port, @port])

    for n <- 1..50 do
      msg = "ping #{n}"
      assert {:ok, [_req, ["portsend", ^ref2, ^msg]]} = crecv(:client_2)
    end

    assert rpc(:client_2, ["portclose", ref2]) == ["ok"]
  end

  test "porthalfopen_a" do
    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, @port]) == {:ok, :ok}
    {:ok, [req, ["portopen", @port, ref1, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    kill(:client_1)

    assert csend(:client_2, ["response", ref1, "ok"], req) == {:ok, :ok}
    {:ok, [_req, ["portclose", ref2]]} = crecv(:client_2)
    assert ref1 == ref2
  end

  test "porthalfopen_b" do
    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, @port]) == {:ok, :ok}

    {:ok, [_req, ["portopen", @port, ref1, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    kill(:client_2)

    {:ok, [_req, [_reason, ref2]]} = crecv(:client_1)
    assert ref1 == ref2
  end

  test "port2x" do
    # First connection
    # Process.sleep(1000)
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, @port]) == {:ok, :ok}
    Process.sleep(1000)
    assert call(:client_1, :peek) == {:ok, :empty}

    {:ok, [req, ["portopen", @port, ref1, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    assert csend(:client_2, ["response", ref1, "ok"], req) == {:ok, :ok}
    {:ok, [_req, ["response", "ok", ref2]]} = crecv(:client_1)
    assert ref1 == ref2

    # Second connection
    assert csend(:client_1, ["portopen", client2id, @port]) == {:ok, :ok}
    {:ok, [req, ["portopen", @port, ref3, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    assert csend(:client_2, ["response", ref3, "ok"], req) == {:ok, :ok}
    {:ok, [_req, ["response", "ok", ref4]]} = crecv(:client_1)
    assert ref3 == ref4
    assert ref1 != ref3

    for _ <- 1..10 do
      # Sending traffic
      assert rpc(:client_2, ["portsend", ref1, "ping from 2 on 1!"]) == ["ok"]

      assert {:ok, [_req, ["portsend", ref1, "ping from 2 on 1!"]]} = crecv(:client_1)

      assert rpc(:client_2, ["portsend", ref4, "ping from 2 on 2!"]) == ["ok"]

      assert {:ok, [_req, ["portsend", ref4, "ping from 2 on 2!"]]} = crecv(:client_1)
    end

    # Closing port1
    assert rpc(:client_1, ["portclose", ref1]) == ["ok"]
    assert {:ok, [_req, ["portclose", ref1]]} = crecv(:client_2)
    # Closing port2
    assert rpc(:client_1, ["portclose", ref4]) == ["ok"]
    assert {:ok, [_req, ["portclose", ref4]]} = crecv(:client_2)
  end

  test "sharedport flags" do
    # Connecting with wrong flags
    client2id = Wallet.address!(clientid(2))
    ["invalid flags"] = rpc(:client_1, ["portopen", client2id, @port, "s"])
  end

  test "sharedport" do
    # Connecting to port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, @port, "rws"]) == {:ok, :ok}
    {:ok, [req, ["portopen", @port, ref1, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    # 'Device' accepts connection
    assert csend(:client_2, ["response", ref1, "ok"], req) == {:ok, :ok}
    {:ok, [_req, ["response", "ok", ref2]]} = crecv(:client_1)
    assert ref1 == ref2

    # Connecting same client to same port again
    ["ok", ref3] = rpc(:client_1, ["portopen", client2id, @port, "rws"])
    assert ref3 != ref2

    for _ <- 1..10 do
      # Sending traffic
      assert rpc(:client_2, ["portsend", ref1, "ping from 2!"]) == ["ok"]
      {:ok, [_req, ["portsend", ^ref3, "ping from 2!"]]} = crecv(:client_1)
      {:ok, [_req, ["portsend", ^ref1, "ping from 2!"]]} = crecv(:client_1)
    end

    # Closing port ref1
    assert rpc(:client_1, ["portclose", ref1]) == ["ok"]

    # Other port ref3 still working
    assert rpc(:client_1, ["portsend", ref3, "ping from 3!"]) == ["ok"]
    {:ok, [_req, ["portsend", ref1, "ping from 3!"]]} = crecv(:client_2)

    # Sending to closed port
    assert rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == [
             "port does not exist"
           ]

    # Closing port ref3
    assert rpc(:client_1, ["portclose", ref3]) == ["ok"]
    assert {:ok, [_req, ["portclose", ref1]]} = crecv(:client_2)
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
    [headers] = rpc(:client_1, ["getblockquick", 30, window_size])

    Enum.reduce(headers, peak - 9, fn [head, _miner], num ->
      head = Enum.map(head, fn [key, value] -> {String.to_atom(key), value} end)
      assert to_num(head[:number]) == num
      num + 1
    end)

    assert length(headers) == window_size

    # Test blockquick with gap
    window_size = 20
    [headers] = rpc(:client_1, ["getblockquick", 30, window_size])

    Enum.reduce(headers, peak - 19, fn [head, _miner], num ->
      head = Enum.map(head, fn [key, value] -> {String.to_atom(key), value} end)
      assert to_num(head[:number]) == num
      num + 1
    end)

    assert length(headers) == window_size

    # Test blockquick without gap
    window_size = 20

    [headers] = rpc(:client_1, ["getblockquick", peak - 10, window_size])

    Enum.reduce(headers, peak - 9, fn [head, _miner], num ->
      head = Enum.map(head, fn [key, value] -> {String.to_atom(key), value} end)
      assert to_num(head[:number]) == num
      num + 1
    end)

    assert length(headers) == 10
  end

  test "transaction" do
    [from, to] = Diode.wallets() |> Enum.reverse() |> Enum.take(2)

    Chain.Worker.set_mode(:disabled)
    to = Wallet.address!(to)

    tx =
      Network.Rpc.create_transaction(from, <<"">>, %{
        "value" => 0,
        "to" => to,
        "gasPrice" => 0
      })

    ["ok"] = rpc(:client_1, ["sendtransaction", to_rlp(tx)])

    Chain.Worker.set_mode(:poll)
    Chain.Worker.work()
    tx
  end

  defp to_rlp(tx) do
    tx |> Chain.Transaction.to_rlp() |> Rlp.encode!()
  end

  defp check_counters() do
    # Checking counters
    rpc(:client_2, ["bytes"])
    {:ok, bytes} = call(:client_2, :bytes)
    assert rpc(:client_2, ["bytes"]) == [bytes |> to_sbin()]

    rpc(:client_1, ["bytes"])
    {:ok, bytes} = call(:client_1, :bytes)
    assert rpc(:client_1, ["bytes"]) == [bytes |> to_sbin()]
  end

  defp kill(atom) do
    # :io.format("Killing ~p~n", [atom])

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
