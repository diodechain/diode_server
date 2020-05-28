defmodule Edge1Client do
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
    Contract.Fleet.set_device_whitelist(clientid(num), true)
    |> Chain.Pool.add_transaction()

    Chain.Worker.work()
  end

  def ensure_client(atom, n) do
    try do
      case rpc(atom, ["ping"]) do
        ["response", "ping", "pong"] -> :ok
        _ -> true = Process.register(client(n), atom)
      end
    rescue
      ArgumentError -> true = Process.register(client(n), atom)
    end

    ExUnit.Assertions.assert(rpc(atom, ["ping"]) == ["response", "ping", "pong"])
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
      state = do_create_ticket(socket, state)
      handle_ticket(socket, state)
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

    msg = Json.encode!(data)
    if socket != nil, do: :ok = :ssl.send(socket, msg)

    %{
      state
      | paid_bytes: state.paid_bytes + @ticket_grace * count,
        unpaid_bytes: state.unpaid_bytes + byte_size(msg)
    }
  end

  def handle_ticket(socket, state = %{events: events}) do
    msg =
      receive do
        {:ssl, _, msg} -> msg
      after
        1500 -> throw(:missing_ticket_reply)
      end

    case Json.decode!(msg) do
      ["response", "ticket", "thanks!", _bytes] ->
        %{state | unpaid_bytes: state.unpaid_bytes + byte_size(msg)}

      ["response", "ticket", "too_low", _peak, conns, bytes, _address, _signature] ->
        state = %{
          state
          | conns: conns,
            paid_bytes: bytes,
            unpaid_bytes: bytes + state.unpaid_bytes + byte_size(msg)
        }

        create_ticket(socket, state)

      _ ->
        handle_ticket(socket, %{state | events: :queue.in(msg, events)})
    end
  end

  def clientloop(socket, state) do
    state = create_ticket(socket, state)

    if not :queue.is_empty(state.events) do
      {{:value, msg}, events} = :queue.out(state.events)
      clientloop(socket, handle_msg(msg, %{state | events: events}))
    end

    receive do
      {:ssl, _, msg} ->
        clientloop(socket, handle_msg(msg, state))

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

      {pid, :quit} ->
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

  def handle_msg(msg, state) do
    state = %{state | unpaid_bytes: state.unpaid_bytes + byte_size(msg)}

    case state.recv do
      nil ->
        # :io.format("handle_msg => state.data: ~p~n", [msg])
        %{state | data: :queue.in(msg, state.data)}

      from ->
        # :io.format("handle_msg => recv (~p): ~p~n", [from, msg])

        send(from, {:ret, msg})
        %{state | recv: nil}
    end
  end

  def rpc(pid, data) do
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

  def crecv(pid) do
    case call(pid, :recv) do
      {:ok, crecv} ->
        Json.decode(crecv)

      error ->
        error
    end
  end

  def call(pid, cmd, timeout \\ 5000) do
    send(pid, {self(), cmd})

    receive do
      {:ret, crecv} ->
        {:ok, crecv}
    after
      timeout ->
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

  @spec client(any) :: pid
  def client(n) do
    cert = "./test/pems/device#{n}_certificate.pem"
    {:ok, socket} = :ssl.connect('localhost', Diode.edge_port(), options(cert), 5000)
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
