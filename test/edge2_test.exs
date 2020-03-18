# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Edge2Test do
  use ExUnit.Case, async: false
  alias Network.Server, as: Server
  alias Network.EdgeV2, as: EdgeHandler
  alias Object.Ticket, as: Ticket
  import Ticket
  import TestHelper

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
        fleet_contract: <<0::unsigned-size(160)>>
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
    assert rpc(:client_1, ["portopen", "wrongid", 3000]) == ["invalid address"]
    assert rpc(:client_1, ["portopen", "12345678901234567890", 3000]) == ["not found"]

    assert rpc(:client_1, ["portopen", Wallet.address!(clientid(1)), 3000]) == [
             "can't connect to yourself"
           ]

    check_counters()
    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    req1 = req_id()
    port = to_bin(3000)
    assert csend(:client_1, ["portopen", client2id, port], req1) == {:ok, :ok}
    {:ok, [req2, ["portopen", ^port, ref1, access_id]]} = crecv(:client_2)
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

  # test "porthalfopen_a" do
  #   # Connecting to "right" port id
  #   client2id = Wallet.address!(clientid(2))
  #   assert csend(:client_1, ["portopen", client2id, 3000]) == {:ok, :ok}
  #   {:ok, ["portopen", 3000, ref1, access_id]} = crecv(:client_2)
  #   assert access_id == Wallet.address!(clientid(1))

  #   kill(:client_1)

  #   assert csend(:client_2, ["response", "portopen", ref1, "ok"]) == {:ok, :ok}
  #   {:ok, ["portclose", ref2]} = crecv(:client_2)
  #   assert ref1 == ref2
  # end

  # test "porthalfopen_b" do
  #   # Connecting to "right" port id
  #   client2id = Wallet.address!(clientid(2))
  #   assert csend(:client_1, ["portopen", client2id, 3000]) == {:ok, :ok}

  #   {:ok, ["portopen", 3000, ref1, access_id]} = crecv(:client_2)
  #   assert access_id == Wallet.address!(clientid(1))

  #   kill(:client_2)

  #   {:ok, [_reason, ref2]} = crecv(:client_1)
  #   assert ref1 == ref2
  # end

  # test "port2x" do
  #   # First connection
  #   # Process.sleep(1000)
  #   client2id = Wallet.address!(clientid(2))
  #   assert csend(:client_1, ["portopen", client2id, 3000]) == {:ok, :ok}
  #   Process.sleep(1000)
  #   assert call(:client_1, :peek) == {:ok, :empty}

  #   {:ok, [req, ["portopen", 3000, ref1, access_id]]} = crecv(:client_2)
  #   assert access_id == Wallet.address!(clientid(1))

  #   assert csend(:client_2, ["response", "portopen", ref1, "ok"], req) == {:ok, :ok}
  #   {:ok, [_req, ["response", "portopen", "ok", ref2]]} = crecv(:client_1)
  #   assert ref1 == ref2

  #   # Second connection
  #   assert csend(:client_1, ["portopen", client2id, 3000]) == {:ok, :ok}
  #   {:ok, [req, ["portopen", 3000, ref3, access_id]]} = crecv(:client_2)
  #   assert access_id == Wallet.address!(clientid(1))

  #   assert csend(:client_2, ["response", ref3, "ok"], req) == {:ok, :ok}
  #   {:ok, [_req, ["response", "portopen", "ok", ref4]]} = crecv(:client_1)
  #   assert ref3 == ref4
  #   assert ref1 != ref3

  #   for _ <- 1..10 do
  #     # Sending traffic
  #     assert rpc(:client_2, ["portsend", ref1, "ping from 2 on 1!"]) == ["ok"]

  #     assert crecv(:client_1) == {:ok, ["portsend", ref1, "ping from 2 on 1!"]}

  #     assert rpc(:client_2, ["portsend", ref4, "ping from 2 on 2!"]) == ["ok"]

  #     assert crecv(:client_1) == {:ok, ["portsend", ref4, "ping from 2 on 2!"]}
  #   end

  #   # Closing port1
  #   assert rpc(:client_1, ["portclose", ref1]) == ["ok"]
  #   assert crecv(:client_2) == {:ok, ["portclose", ref1]}
  #   # Closing port2
  #   assert rpc(:client_1, ["portclose", ref4]) == ["ok"]
  #   assert crecv(:client_2) == {:ok, ["portclose", ref4]}
  # end

  # test "sharedport flags" do
  #   # Connecting with wrong flags
  #   client2id = Wallet.address!(clientid(2))
  #   ["invalid flags"] = rpc(:client_1, ["portopen", client2id, 3000, "s"])
  # end

  # test "sharedport" do
  #   # Connecting to port id
  #   client2id = Wallet.address!(clientid(2))
  #   port = to_bin(3000)
  #   assert csend(:client_1, ["portopen", client2id, port, "rws"]) == {:ok, :ok}
  #   {:ok, [req, ["portopen", ^port, ref1, access_id]]} = crecv(:client_2)
  #   assert access_id == Wallet.address!(clientid(1))

  #   # 'Device' accepts connection
  #   assert csend(:client_2, ["response", ref1, "ok"], req) == {:ok, :ok}
  #   {:ok, [_req, ["response", "ok", ref2]]} = crecv(:client_1)
  #   assert ref1 == ref2

  #   # Connecting same client to same port again
  #   ["ok", ref3] = rpc(:client_1, ["portopen", client2id, 3000, "rws"])
  #   assert ref3 != ref2

  #   for _ <- 1..10 do
  #     # Sending traffic
  #     assert rpc(:client_2, ["portsend", ref1, "ping from 2!"]) == ["ok"]
  #     {:ok, [_req, ["portsend", ^ref3, "ping from 2!"]]} = crecv(:client_1)
  #     {:ok, [_req, ["portsend", ^ref1, "ping from 2!"]]} = crecv(:client_1)
  #   end

  #   # Closing port ref1
  #   assert rpc(:client_1, ["portclose", ref1]) == ["ok"]

  #   # Other port ref3 still working
  #   assert rpc(:client_1, ["portsend", ref3, "ping from 3!"]) == ["ok"]
  #   {:ok, [_req, ["portsend", ref1, "ping from 3!"]]} = crecv(:client_2)

  #   # Sending to closed port
  #   assert rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == [
  #            "port does not exist"
  #          ]

  #   # Closing port ref3
  #   assert rpc(:client_1, ["portclose", ref3]) == ["ok"]
  #   assert crecv(:client_2) == {:ok, ["portclose", ref1]}
  # end

  # test "doubleconn" do
  #   old_pid = Process.whereis(:client_1)
  #   assert true == Process.alive?(old_pid)
  #   new_client = client(1)

  #   assert call(new_client, :ping) == {:ok, :pong}

  #   Process.sleep(1000)
  #   assert false == Process.alive?(old_pid)
  # end

  # test "getblockquick" do
  #   for _ <- 1..50, do: Chain.Worker.work()
  #   peak = Chain.peak()

  #   # Test blockquick with gap
  #   window_size = 10
  #   [headers] = rpc(:client_1, ["getblockquick", 30, window_size])

  #   Enum.reduce(headers, peak - 9, fn [head, _miner], num ->
  #     head = Enum.map(head, fn [key, value] -> {String.to_atom(key), value} end)
  #     assert to_num(head[:number]) == num
  #     num + 1
  #   end)

  #   assert length(headers) == window_size

  #   # Test blockquick with gap
  #   window_size = 20
  #   [headers] = rpc(:client_1, ["getblockquick", 30, window_size])

  #   Enum.reduce(headers, peak - 19, fn [head, _miner], num ->
  #     head = Enum.map(head, fn [key, value] -> {String.to_atom(key), value} end)
  #     assert to_num(head[:number]) == num
  #     num + 1
  #   end)

  #   assert length(headers) == window_size

  #   # Test blockquick without gap
  #   window_size = 20

  #   [headers] = rpc(:client_1, ["getblockquick", peak - 10, window_size])

  #   Enum.reduce(headers, peak - 9, fn [head, _miner], num ->
  #     head = Enum.map(head, fn [key, value] -> {String.to_atom(key), value} end)
  #     assert to_num(head[:number]) == num
  #     num + 1
  #   end)

  #   assert length(headers) == 10
  # end

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
    :io.format("Killing ~p~n", [atom])

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

  defp ensure_clients() do
    :io.format("ensure_clients()~n")
    ensure_client(:client_1, 1)
    ensure_client(:client_2, 2)
    :ok
  end

  defp to_bin(num) do
    Rlpx.num2bin(num)
  end

  defp to_sbin(num) do
    Rlpx.int2bin(num)
  end

  defp to_num(bin) do
    Rlpx.bin2num(bin)
  end

  defp ensure_client(atom, n) do
    :io.format("ensure_client(~p)~n", [atom])

    try do
      case rpc(atom, ["ping"]) do
        ["pong"] ->
          :ok

        other ->
          IO.puts("received #{inspect(other)}")
          true = Process.register(client(n), atom)
      end
    rescue
      ArgumentError -> true = Process.register(client(n), atom)
    end

    assert rpc(atom, ["ping"]) == ["pong"]
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
    if ub >= pb + @ticket_grace and not :persistent_term.get(:no_tickets) do
      {req, state} = do_create_ticket(socket, state)
      handle_ticket(socket, state, req)
    else
      state
    end
  end

  defp do_create_ticket(socket, state = %{unpaid_bytes: unpaid_bytes, paid_bytes: paid_bytes}) do
    count = div(unpaid_bytes + 400 - paid_bytes, @ticket_grace)

    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: state.conns,
        total_bytes: paid_bytes + @ticket_grace * count,
        local_address: "spam",
        block_number: Chain.peak(),
        fleet_contract: <<0::unsigned-size(160)>>
      )
      |> Ticket.device_sign(state.key)

    data = [
      "ticket",
      Ticket.block_number(tck),
      Ticket.fleet_contract(tck),
      Ticket.total_connections(tck),
      Ticket.total_bytes(tck),
      Ticket.local_address(tck),
      Ticket.device_signature(tck)
    ]

    req = req_id()
    msg = Rlp.encode!([req, data])
    if socket != nil, do: :ok = :ssl.send(socket, msg)

    {req,
     %{
       state
       | paid_bytes: state.paid_bytes + @ticket_grace * count,
         unpaid_bytes: state.unpaid_bytes + byte_size(msg)
     }}
  end

  def handle_ticket(socket, state = %{events: events}, req) do
    msg =
      receive do
        {:ssl, _, msg} -> msg
      after
        1500 -> throw(:missing_ticket_reply)
      end

    case Rlp.decode!(msg) do
      [^req, ["response", "thanks!", _bytes]] ->
        %{state | unpaid_bytes: state.unpaid_bytes + byte_size(msg)}

      [^req, ["response", "too_low", _peak, conns, bytes, _address, _signature]] ->
        state = %{
          state
          | conns: to_num(conns),
            paid_bytes: to_num(bytes),
            unpaid_bytes: bytes + state.unpaid_bytes + byte_size(msg)
        }

        create_ticket(socket, state)

      _ ->
        handle_ticket(socket, %{state | events: :queue.in(msg, events)}, req)
    end
  end

  def clientloop(socket, state) do
    state = create_ticket(socket, state)

    if not :queue.is_empty(state.events) do
      {{:value, msg}, events} = :queue.out(state.events)
      clientloop(socket, handle_msg(msg, %{state | events: events}))
    end

    receive do
      {:ssl, _, rlp} ->
        clientloop(socket, handle_msg(rlp, state))

      {:ssl_closed, _} ->
        IO.puts("Remote closed the connection, #{inspect(state)}")

        if :queue.is_empty(state.data) do
          :ok
        else
          clientloop(nil, state)
        end

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

        if socket == nil and :queue.is_empty(state.data) do
          :ok
        else
          clientloop(socket, state)
        end

      {pid, {:recv, req_id}} ->
        list = :queue.to_list(state.data)
        item = Enum.find(list, nil, fn [req | _rest] -> req == req_id end)

        state =
          if item == nil do
            %{state | recv_id: Map.put(state.recv_id, req_id, pid)}
          else
            list = List.delete(list, item)
            send(pid, {:ret, item})
            %{state | data: :queue.from_list(list)}
          end

        if socket == nil and :queue.is_empty(state.data) do
          :ok
        else
          clientloop(socket, state)
        end

      {pid, :quit} ->
        :io.format("Got quit!~n")
        send(pid, {:ret, :ok})

      {pid, :bytes} ->
        send(pid, {:ret, state.unpaid_bytes - state.paid_bytes})
        clientloop(socket, state)

      {pid, :ping} ->
        send(pid, {:ret, :pong})
        clientloop(socket, state)

      {pid, :peerid} ->
        send(pid, {:ret, Wallet.from_pubkey(Certs.extract(socket))})
        clientloop(socket, state)

      {pid, {:send, data}} ->
        if socket != nil, do: :ok = :ssl.send(socket, data)
        send(pid, {:ret, :ok})
        state = %{state | unpaid_bytes: state.unpaid_bytes + byte_size(data)}
        clientloop(socket, state)

      msg ->
        IO.puts("Unhandled: #{inspect(msg)}")
    end
  end

  defp handle_msg(rlp, state) do
    state = %{state | unpaid_bytes: state.unpaid_bytes + byte_size(rlp)}

    msg = [req | _rest] = Rlp.decode!(rlp)

    case Map.get(state.recv_id, req) do
      nil ->
        case state.recv do
          nil ->
            :io.format("handle_msg => state.data: ~p~n", [msg])
            %{state | data: :queue.in(msg, state.data)}

          from ->
            send(from, {:ret, msg})
            :io.format("handle_msg => recv (~p): ~p~n", [from, msg])
            %{state | recv: nil}
        end

      from ->
        send(from, {:ret, msg})
        :io.format("handle_msg => recv_id (~p): ~p~n", [from, msg])
        %{state | recv_id: Map.delete(state.recv_id, req)}
    end
  end

  defp rpc(pid, data) do
    :io.format("rpc(~p, ~p)~n", [pid, data])
    req = req_id()

    with {:ok, _} <- csend(pid, data, req),
         {:ok, crecv} <- crecv(pid, req) do
      tl(Enum.at(crecv, 1))
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp req_id() do
    :io.format("req_id()~n")

    id = Process.get(:req_id, 1)
    Process.put(:req_id, id + 1)
    ret = to_bin(id)

    :io.format("req_id()= ~p~n", [ret])
    ret
  end

  def csend(pid, data, req \\ req_id()) do
    :io.format("csend(~p, ~p, ~p)~n", [pid, data, req])
    call(pid, {:send, Rlp.encode!([req | [data]])})
  end

  defp crecv(pid) do
    case call(pid, :recv) do
      {:ok, crecv} ->
        {:ok, crecv}

      error ->
        error
    end
  end

  defp crecv(pid, req) do
    case call(pid, {:recv, req}) do
      {:ok, crecv} ->
        {:ok, crecv}

      error ->
        error
    end
  end

  defp call(pid, cmd, timeout \\ 5000) do
    send(pid, {self(), cmd})

    receive do
      {:ret, crecv} ->
        :io.format("call(~p, ~p ~p) => [~p]~n", [pid, cmd, timeout, crecv])
        {:ok, crecv}
    after
      timeout ->
        :io.format("call(~p, ~p ~p) => timeout!~n", [pid, cmd, timeout])
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

  defp client(n) do
    :io.format("client(~p)~n", [n])
    cert = "./test/pems/device#{n}_certificate.pem"
    {:ok, socket} = :ssl.connect('localhost', Diode.edge2_port(), options(cert), 5000)
    wallet = clientid(n)
    key = Wallet.privkey!(wallet)
    fleet = <<0::160>>

    {conns, bytes} =
      case TicketStore.find(Wallet.address!(wallet), fleet, Chain.epoch()) do
        nil -> {1, 0}
        tck -> {Ticket.total_connections(tck) + 1, Ticket.total_bytes(tck)}
      end

    state = %{
      data: :queue.new(),
      recv: nil,
      recv_id: %{},
      key: key,
      unpaid_bytes: bytes,
      paid_bytes: bytes,
      conns: conns,
      events: :queue.new()
    }

    pid = Process.spawn(__MODULE__, :clientboot, [socket, state], [])
    :ok = :ssl.controlling_process(socket, pid)
    :ok = :ssl.setopts(socket, active: true)
    send(pid, :go)
    pid
  end
end
