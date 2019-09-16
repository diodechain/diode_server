defmodule EdgeTest do
  use ExUnit.Case, async: true
  alias Network.Server, as: Server
  alias Network.EdgeHandler, as: EdgeHandler
  alias Object.Ticket, as: Ticket
  import Ticket

  test "connect" do
    # Test that clients are connected
    assert call(:client_1, :ping) == {:ok, :pong}
    assert call(:client_2, :ping) == {:ok, :pong}
    conns = Server.get_connections(EdgeHandler)
    assert map_size(conns) == 2

    # Test that clients are connected to this node
    {:ok, peer_1} = call(:client_1, :peerid)
    {:ok, peer_2} = call(:client_2, :peerid)
    assert Wallet.equal?(Store.wallet(), peer_1)
    assert Wallet.equal?(Store.wallet(), peer_2)

    # Test that clients connected match the test file identities
    [id1, id2] = Map.keys(conns)

    if Wallet.equal?(id1, clientid(1)) do
      assert Wallet.equal?(id2, clientid(2))
    else
      assert Wallet.equal?(id1, clientid(2))
      assert Wallet.equal?(id2, clientid(1))
    end
  end

  test "getblock" do
    assert rpc(:client_1, ["getblockpeak"]) == ["response", "getblockpeak", Chain.peak()]
  end

  test "getaccount" do
    ["error", "getaccount", "account does not exist"] =
      rpc(:client_1, ["getaccount", Chain.peak(), "01234567890123456789"])

    {wallet, acc} = hd(Chain.GenesisFactory.genesis_accounts())
    addr = Wallet.address!(wallet)

    ["response", "getaccount", ret, _proof] = rpc(:client_1, ["getaccount", Chain.peak(), addr])

    assert ret["code"] == Chain.Account.codehash(acc)
    assert ret["balance"] == acc.balance
  end

  test "getaccountvalue" do
    ["error", "getaccountvalue", "account does not exist"] =
      rpc(:client_1, ["getaccountvalue", Chain.peak(), "01234567890123456789", 0])

    {wallet, _balance} = hd(Chain.GenesisFactory.genesis_accounts())
    addr = Wallet.address!(wallet)

    ["response", "getaccountvalue", ret] =
      rpc(:client_1, ["getaccountvalue", Chain.peak(), addr, 0])

    # Should be empty
    assert length(ret) == 2
  end

  test "ticket" do
    TicketStore.clear()
    :persistent_term.put(:no_tickets, true)

    tck =
      ticket(
        server_id: Wallet.address!(Store.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        peak_block: Chain.block(Chain.peak()).header.block_hash,
        fleet_contract: <<0::unsigned-size(160)>>
      )
      |> Ticket.device_sign(clientkey(1))

    # The first ticket submission should work
    assert rpc(:client_1, [
             "ticket",
             Ticket.peak_block(tck),
             Ticket.fleet_contract(tck),
             Ticket.total_connections(tck),
             Ticket.total_bytes(tck),
             Ticket.local_address(tck),
             Ticket.device_signature(tck)
           ]) ==
             [
               "response",
               "ticket",
               "thanks!"
             ]

    # Submitting a second ticket with the same count should fail
    assert rpc(:client_1, [
             "ticket",
             Ticket.peak_block(tck),
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
               Ticket.peak_block(tck),
               Ticket.total_connections(tck),
               Ticket.total_bytes(tck),
               Ticket.local_address(tck),
               Ticket.device_signature(tck)
             ]

    ["response", "getobject", loc2] = rpc(:client_1, ["getobject", Wallet.address!(clientid(1))])

    loc2 = Object.decode_list!(loc2)
    assert Ticket.device_blob(tck) == Ticket.device_blob(loc2)

    assert Secp256k1.verify(
             Store.wallet(),
             Ticket.server_blob(loc2),
             Ticket.server_signature(loc2)
           ) == true

    public = Secp256k1.recover!(Ticket.server_signature(loc2), Ticket.server_blob(loc2))
    id = Wallet.from_pubkey(public) |> Wallet.address!()

    assert Wallet.address!(Store.wallet()) == Wallet.address!(Wallet.from_pubkey(public))
    assert id == Wallet.address!(Store.wallet())

    obj = Diode.self()
    assert(Object.key(obj) == id)
    enc = Json.encode!(Object.encode_list!(obj))
    assert obj == Object.decode_list!(Json.decode!(enc))

    # Getnode
    ["response", "getnode", node] = rpc(:client_1, ["getnode", id])
    node = Object.decode_list!(node)
    assert(Object.key(node) == id)

    # Testing disconnect
    ["goodbye", "ticket expected", "you might get blacklisted"] =
      rpc(:client_1, ["garbage", String.pad_leading("", 1024)])

    # {:ok, ["goodbye", "ticket expected", "you might get blacklisted"]} = crecv(:client_1)
    {:error, :timeout} = crecv(:client_1)
  end

  test "port" do
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

    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, 3000]) == {:ok, :ok}
    {:ok, ["portopen", 3000, ref1, access_id]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    assert csend(:client_2, ["response", "portopen", ref1, "ok"]) == {:ok, :ok}
    {:ok, ["response", "portopen", "ok", ref2]} = crecv(:client_1)
    assert ref1 == ref2

    for _ <- 1..10 do
      # Sending traffic
      assert rpc(:client_2, ["portsend", ref1, "ping from 2!"]) == ["response", "portsend", "ok"]
      assert crecv(:client_1) == {:ok, ["portsend", ref1, "ping from 2!"]}

      # Both ways
      assert rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == ["response", "portsend", "ok"]
      assert crecv(:client_2) == {:ok, ["portsend", ref1, "ping from 1!"]}
    end

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

  setup do
    :persistent_term.put(:no_tickets, false)
    ensure_clients()
  end

  setup_all do
    IO.puts("Starting clients")
    :persistent_term.put(:no_tickets, false)
    ensure_clients()

    on_exit(fn ->
      IO.puts("Killing clients")
      ensure_clients()
      {:ok, _} = call(:client_1, :quit)
      {:ok, _} = call(:client_2, :quit)
    end)
  end

  defp kill(atom) do
    case Process.whereis(atom) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        wait(atom)
    end
  end

  defp wait(atom) do
    case Process.whereis(atom) do
      nil ->
        :ok

      _pid ->
        Process.sleep(100)
        wait(atom)
    end
  end

  defp ensure_clients() do
    if dead?(:client_1) do
      true = Process.register(client(1), :client_1)
      assert rpc(:client_1, ["ping"]) == ["response", "ping", "pong"]
    end

    if dead?(:client_2) do
      true = Process.register(client(2), :client_2)
      assert rpc(:client_2, ["ping"]) == ["response", "ping", "pong"]
    end

    :ok
  end

  defp dead?(atom) do
    case Process.whereis(atom) do
      nil ->
        true

      pid ->
        ret = not Process.alive?(pid)
        ret && Process.unregister(atom)
        ret
    end
  end

  def check(_cert, event, state) do
    case event do
      {:bad_cert, :selfsigned_peer} -> {:valid, state}
      _ -> {:fail, event}
    end
  end

  def clientboot(socket, state) do
    receive do
      :go -> clientloop(socket, state)
    end
  end

  defp create_ticket(socket, state = %{unpaid_bytes: ub, paid_bytes: pb}) do
    if ub >= pb + 1024 and not :persistent_term.get(:no_tickets) do
      do_create_ticket(socket, state)
    else
      state
    end
  end

  defp do_create_ticket(socket, state) do
    tck =
      ticket(
        server_id: Wallet.address!(Store.wallet()),
        total_connections: state.conns,
        total_bytes: state.paid_bytes + 1024,
        local_address: "spam",
        peak_block: Chain.block(Chain.peak()).header.block_hash,
        fleet_contract: <<0::unsigned-size(160)>>
      )
      |> Ticket.device_sign(state.key)

    data = [
      "ticket",
      Ticket.peak_block(tck),
      Ticket.fleet_contract(tck),
      Ticket.total_connections(tck),
      Ticket.total_bytes(tck),
      Ticket.local_address(tck),
      Ticket.device_signature(tck)
    ]

    :ssl.send(socket, Json.encode!(data))

    %{state | paid_bytes: state.paid_bytes + 1024}
  end

  def handle_tickets(socket, state, msg) do
    if not :persistent_term.get(:no_tickets) do
      case Json.decode!(msg) do
        ["response", "ticket", "thanks!"] ->
          state

        ["response", "ticket", "too_low", _peak, conns, bytes, _address, _signature] ->
          state = %{state | conns: conns, paid_bytes: bytes, unpaid_bytes: bytes + 1024}
          create_ticket(socket, state)

        _ ->
          false
      end
    else
      false
    end
  end

  def clientloop(socket, state) do
    state = create_ticket(socket, state)

    receive do
      {:ssl, _, msg} ->
        # IO.puts("Received #{msg}")
        state = %{state | unpaid_bytes: state.unpaid_bytes + byte_size(msg)}

        case handle_tickets(socket, state, msg) do
          false ->
            case state.recv do
              nil ->
                clientloop(socket, %{state | data: :queue.in(msg, state.data)})

              from ->
                send(from, {:ret, msg})
                clientloop(socket, %{state | recv: nil})
            end

          state ->
            clientloop(socket, state)
        end

      {:ssl_closed, _} ->
        IO.puts("Remote closed the connection")

      {pid, :peek} ->
        send(pid, {:ret, :queue.peek(state.data)})
        clientloop(socket, state)

      {pid, :recv} ->
        state =
          if :queue.is_empty(state.data) do
            %{state | recv: pid}
          else
            {{:value, crecv}, queue} = :queue.out(state.data)
            send(pid, {:ret, crecv})
            %{state | data: queue}
          end

        clientloop(socket, state)

      {pid, :quit} ->
        send(pid, {:ret, :ok})

      {pid, :ping} ->
        send(pid, {:ret, :pong})
        clientloop(socket, state)

      {pid, :peerid} ->
        send(pid, {:ret, Wallet.from_pubkey(Certs.extract(socket))})
        clientloop(socket, state)

      {pid, {:send, data}} ->
        # IO.puts("Sending #{data}")
        :ok = :ssl.send(socket, data)
        send(pid, {:ret, :ok})
        state = %{state | unpaid_bytes: state.unpaid_bytes + byte_size(data)}
        clientloop(socket, state)

      msg ->
        IO.puts("Unhanloced: #{inspect(msg)}")
    end
  end

  defp rpc(pid, data) do
    with {:ok, _} <- csend(pid, data),
         {:ok, crecv} <- crecv(pid) do
      crecv
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def csend(pid, data) do
    call(pid, {:send, Json.encode!(data)})
  end

  defp crecv(pid) do
    case call(pid, :recv) do
      {:ok, crecv} ->
        Json.decode(crecv)

      error ->
        error
    end
  end

  defp call(pid, cmd) do
    send(pid, {self(), cmd})

    receive do
      {:ret, crecv} ->
        {:ok, crecv}
    after
      5000 ->
        {:error, :timeout}
    end
  end

  defp options(cert) do
    [
      mode: :binary,
      packet: 2,
      certfile: cert,
      cacertfile: cert,
      versions: [:"tlsv1.2"],
      verify: :verify_peer,
      verify_fun: {&__MODULE__.check/3, nil},
      fail_if_no_peer_cert: true,
      eccs: [:secp256k1],
      active: false,
      reuseaddr: true,
      keyfile: cert
    ]
  end

  defp clientid(n) do
    Wallet.from_privkey(clientkey(n))
  end

  defp clientkey(n) do
    Certs.private_from_file("./test/pems/device#{n}_certificate.pem")
  end

  defp client(n) do
    cert = "./test/pems/device#{n}_certificate.pem"
    {:ok, socket} = :ssl.connect('localhost', 41043, options(cert), 5000)
    wallet = clientid(n)
    key = Wallet.privkey!(wallet)
    fleet = <<0::160>>

    {conns, bytes} =
      case TicketStore.find(Wallet.address!(wallet), fleet) do
        nil -> {1, 0}
        tck -> {Ticket.total_connections(tck) + 1, Ticket.total_bytes(tck)}
      end

    state = %{
      data: :queue.new(),
      recv: nil,
      key: key,
      unpaid_bytes: bytes,
      paid_bytes: bytes,
      conns: conns
    }

    pid = Process.spawn(__MODULE__, :clientboot, [socket, state], [])
    :ok = :ssl.controlling_process(socket, pid)
    :ok = :ssl.setopts(socket, active: true)
    send(pid, :go)
    pid
  end
end
