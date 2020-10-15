# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Edge2Client do
  alias Object.Ticket, as: Ticket
  require ExUnit.Assertions
  import Ticket

  @ticket_grace 4096

  def ensure_clients() do
    # :io.format("ensure_clients()~n")
    ensure_client(:client_1, 1)
    whitelist_client(1)
    ensure_client(:client_2, 2)
    whitelist_client(2)
    :ok
  end

  def whitelist_client(num) do
    Contract.Fleet.set_device_allowlist(clientid(num), true)
    |> Chain.Pool.add_transaction()

    Chain.Worker.work()
  end

  def to_bin(num) do
    Rlpx.num2bin(num)
  end

  def to_sbin(num) do
    Rlpx.int2bin(num)
  end

  def to_num(bin) do
    Rlpx.bin2num(bin)
  end

  def ensure_client(atom, n) do
    # :io.format("ensure_client(~p)~n", [atom])

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

    ExUnit.Assertions.assert(rpc(atom, ["ping"]) == ["pong"])
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

  def create_ticket(socket, state = %{unpaid_bytes: ub, paid_bytes: pb}) do
    if ub >= pb + @ticket_grace and not :persistent_term.get(:no_tickets) do
      {req, state} = do_create_ticket(socket, state)
      handle_ticket(socket, state, req)
    else
      state
    end
  end

  def do_create_ticket(socket, state = %{unpaid_bytes: unpaid_bytes, paid_bytes: paid_bytes}) do
    count = div(unpaid_bytes + 400 - paid_bytes, @ticket_grace)

    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: state.conns,
        total_bytes: paid_bytes + @ticket_grace * count,
        local_address: "spam",
        block_number: Chain.peak(),
        fleet_contract: Diode.fleet_address()
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

      [^req, other] ->
        throw("Unexpected ticket reply: #{inspect(other)}")

      _other ->
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
        # :io.format("Got quit!~n")
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

  def handle_msg(rlp, state) do
    state = %{state | unpaid_bytes: state.unpaid_bytes + byte_size(rlp)}

    msg = [req | _rest] = Rlp.decode!(rlp)

    case Map.get(state.recv_id, req) do
      nil ->
        case state.recv do
          nil ->
            # :io.format("handle_msg => state.data: ~p~n", [msg])
            %{state | data: :queue.in(msg, state.data)}

          from ->
            send(from, {:ret, msg})
            # :io.format("handle_msg => recv (~p): ~p~n", [from, msg])
            %{state | recv: nil}
        end

      from ->
        send(from, {:ret, msg})
        # :io.format("handle_msg => recv_id (~p): ~p~n", [from, msg])
        %{state | recv_id: Map.delete(state.recv_id, req)}
    end
  end

  def rpc(pid, data) do
    # :io.format("rpc(~p, ~p)~n", [pid, data])
    req = req_id()

    with {:ok, _} <- csend(pid, data, req),
         {:ok, crecv} <- crecv(pid, req) do
      tl(Enum.at(crecv, 1))
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def req_id() do
    # :io.format("req_id()~n")

    id = Process.get(:req_id, 1)
    Process.put(:req_id, id + 1)
    ret = to_bin(id)

    # :io.format("req_id()= ~p~n", [ret])
    ret
  end

  def csend(pid, data, req \\ req_id()) do
    # :io.format("csend(~p, ~p, ~p)~n", [pid, data, req])
    call(pid, {:send, Rlp.encode!([req | [data]])})
  end

  def crecv(pid) do
    case call(pid, :recv) do
      {:ok, crecv} ->
        {:ok, crecv}

      error ->
        error
    end
  end

  def crecv(pid, req) do
    case call(pid, {:recv, req}) do
      {:ok, crecv} ->
        {:ok, crecv}

      error ->
        error
    end
  end

  def call(pid, cmd, timeout \\ 5000) do
    send(pid, {self(), cmd})

    receive do
      {:ret, crecv} ->
        # :io.format("call(~p, ~p ~p) => [~p]~n", [pid, cmd, timeout, crecv])
        {:ok, crecv}
    after
      timeout ->
        # :io.format("call(~p, ~p ~p) => timeout!~n", [pid, cmd, timeout])
        {:error, :timeout}
    end
  end

  def options(cert) do
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

  def client(n) do
    # :io.format("client(~p)~n", [n])
    cert = "./test/pems/device#{n}_certificate.pem"
    {:ok, socket} = :ssl.connect('localhost', Diode.edge2_port(), options(cert), 5000)
    wallet = clientid(n)
    key = Wallet.privkey!(wallet)
    fleet = Diode.fleet_address()

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

  def clientid(n) do
    Wallet.from_privkey(clientkey(n))
  end

  def clientkey(n) do
    Certs.private_from_file("./test/pems/device#{n}_certificate.pem")
  end
end
