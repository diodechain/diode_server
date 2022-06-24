# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Server do
  @moduledoc """
    General TLS 1.2 socket server that ensures:
      * Secp256k1 handshakes
      * Identities on server and client
      * Self-signed certs on both of them

    Then it spawns client connection based on the protocol handler
  """
  use GenServer
  require Logger

  @type sslsocket() :: any()

  defstruct sockets: %{},
            clients: %{},
            protocol: nil,
            ports: [],
            opts: [],
            pid: nil,
            acceptors: %{},
            self_conns: []

  @type t :: %Network.Server{
          sockets: %{integer() => sslsocket()},
          clients: map(),
          protocol: atom(),
          ports: [integer()],
          opts: %{},
          acceptors: %{integer() => pid()},
          pid: pid(),
          self_conns: []
        }

  def start_link({port, protocolHandler, opts}) do
    GenServer.start_link(__MODULE__, {port, protocolHandler, opts}, name: opts.name)
  end

  def child(ports, protocolHandler, opts \\ []) do
    opts =
      %{name: protocolHandler}
      |> Map.merge(Map.new(opts))

    Supervisor.child_spec({__MODULE__, {List.wrap(ports), protocolHandler, opts}}, id: opts.name)
  end

  @impl true
  @spec init({integer(), atom(), %{}}) :: {:ok, Network.Server.t(), {:continue, :accept}}
  def init({ports, protocolHandler, opts}) when is_list(ports) do
    :erlang.process_flag(:trap_exit, true)

    {ports, sockets} =
      Enum.reduce(ports, {[], %{}}, fn port, {ports, sockets} ->
        case :ssl.listen(port, protocolHandler.ssl_options(opts)) do
          {:ok, socket} ->
            {ports ++ [port], Map.put(sockets, port, socket)}

          {:error, reason} ->
            Logger.error(
              "Failed to open #{inspect(protocolHandler)} port: #{inspect(port)} for reason: #{
                inspect(reason)
              }"
            )

            {ports, sockets}
        end
      end)

    {:ok,
     %Network.Server{
       sockets: sockets,
       protocol: protocolHandler,
       ports: ports,
       opts: opts,
       pid: self()
     }, {:continue, :accept}}
  end

  def check(_cert, event, state) do
    case event do
      {:bad_cert, :selfsigned_peer} ->
        {:valid, state}

      other ->
        IO.puts("Failed for #{inspect(other)}")
        {:fail, event}
    end
  end

  def get_connections(name) do
    GenServer.call(name, :get_connections)
  end

  def ensure_node_connection(name, node_id, address, port) do
    GenServer.call(name, {:ensure_node_connection, node_id, address, port})
  end

  def handle_client_exit(state = %{clients: clients}, pid, reason) do
    case Map.get(clients, pid) do
      nil ->
        :io.format("~0p Connection setup failed before register (~0p)~n", [
          state.protocol,
          {pid, reason}
        ])

        {:noreply, state}

      key ->
        if reason != :normal do
          :io.format("~0p Connection failed (~0p)~n", [
            state.protocol,
            {pid, reason}
          ])
        end

        clients = Map.drop(clients, [pid, key])

        clients =
          Enum.find(clients, nil, fn {_pid, key0} -> key0 == key end)
          |> case do
            nil -> clients
            {pid0, key0} -> Map.put(clients, key0, {pid0, System.os_time(:millisecond)})
          end

        {:noreply, %{state | clients: clients}}
    end
  end

  def handle_acceptor_exit(state = %{acceptors: acceptors}, port, pid, reason) do
    :io.format("~p acceptor crashed ~p~n", [state.protocol, reason])

    acceptors =
      Map.delete(acceptors, pid)
      |> Map.put(spawn_link(fn -> do_accept(state, port) end), port)

    {:noreply, %{state | acceptors: acceptors}}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state = %{acceptors: acceptors}) do
    port = acceptors[pid]

    if port do
      handle_acceptor_exit(state, port, pid, reason)
    else
      handle_client_exit(state, pid, reason)
    end
  end

  def handle_info(msg, state) do
    :io.format("~p unhandled info: ~0p~n", [state.protocol, msg])
    {:noreply, state}
  end

  defp to_key(nil) do
    Wallet.new() |> Wallet.address!()
  end

  defp to_key(wallet) do
    Wallet.address!(wallet)
  end

  @impl true
  def handle_call(:get_connections, _from, state) do
    result =
      Enum.filter(state.clients, fn {_key, value} ->
        case value do
          {pid, _timestamp} -> is_pid(pid)
          _ -> false
        end
      end)
      |> Enum.map(fn {key, {pid, _timestamp}} -> {key, pid} end)
      |> Map.new()

    {:reply, result, state}
  end

  def handle_call({:ensure_node_connection, node_id, address, port}, _from, state) do
    if Wallet.equal?(Diode.miner(), node_id) do
      client = Enum.find(state.self_conns, fn pid -> Process.alive?(pid) end)

      if client != nil do
        {:reply, client, state}
      else
        worker = start_worker!(state, [:connect, node_id, "localhost", Diode.peer_port()])
        {:reply, worker, %{state | self_conns: [worker]}}
      end
    else
      key = to_key(node_id)

      case Map.get(state.clients, key) do
        {pid, _timestamp} ->
          {:reply, pid, state}

        _ ->
          worker = start_worker!(state, [:connect, node_id, address, port])

          clients =
            Map.put(state.clients, key, {worker, System.os_time(:millisecond)})
            |> Map.put(worker, key)

          {:reply, worker, %{state | clients: clients}}
      end
    end
  end

  def handle_call({:register, node_id}, {pid, _}, state) do
    if Wallet.equal?(Diode.miner(), node_id) do
      state = %{state | self_conns: [pid | state.self_conns]}
      {:reply, {:ok, hd(state.ports)}, state}
    else
      register_node(node_id, pid, state)
    end
  end

  defp register_node(node_id, pid, state) do
    # Checking whether pid is already registered and remove for the update
    clients = Map.delete(state.clients, Map.get(state.clients, pid))
    key = to_key(node_id)
    now = System.os_time(:millisecond)

    # Checking whether node_id is already registered
    case Map.get(clients, key) do
      nil ->
        # best case this is a new connection.
        clients =
          Map.put(clients, key, {pid, now})
          |> Map.put(pid, key)

        {:reply, {:ok, hd(state.ports)}, %{state | clients: clients}}

      {^pid, timestamp} ->
        # also ok, this pid is already registered to this node_id
        clients =
          Map.put(clients, key, {pid, timestamp})
          |> Map.put(pid, key)

        {:reply, {:ok, hd(state.ports)}, %{state | clients: clients}}

      {other_pid, timestamp} ->
        # hm, another pid is given for the node_id logging this

        if now - timestamp > 5000 do
          :io.format(
            "~p Handshake anomaly(~p): #{Wallet.printable(node_id)} is already connected: ~180p~n",
            [state.protocol, pid, {other_pid, Process.alive?(other_pid)}]
          )

          GenServer.cast(other_pid, :stop)

          clients =
            Map.put(clients, key, {pid, now})
            |> Map.put(pid, key)

          {:reply, {:ok, hd(state.ports)}, %{state | clients: clients}}
        else
          # the existing connection is fresh (younger than 5000ms) so we keep the old connection
          # and deny for now
          {:reply, {:deny, hd(state.ports)}, %{state | clients: clients}}
        end
    end
  end

  @impl true
  def handle_continue(:accept, state = %{ports: ports}) do
    acceptors =
      Enum.reduce(ports, %{}, fn port, acceptors ->
        Map.put(acceptors, spawn_link(fn -> do_accept(state, port) end), port)
      end)

    {:noreply, %{state | acceptors: acceptors}}
  end

  defp do_accept(state, port) do
    case :ssl.transport_accept(state.sockets[port], 1000) do
      {:error, :timeout} ->
        :ok

      {:error, :closed} ->
        # Connection abort before handshake
        :io.format("~p Anomaly - Connection closed before TLS handshake~n", [state.protocol])

      {:ok, newSocket} ->
        spawn_link(fn ->
          peername = :ssl.peername(newSocket)

          with {:ok, {_address, _port}} <- peername,
               {:ok, newSocket2} <- :ssl.handshake(newSocket, 25000) do
            worker = start_worker!(state, :init)
            :ok = :ssl.controlling_process(newSocket2, worker)
            send(worker, {:init, newSocket2})
          else
            {:error, error} ->
              :io.format("~p Handshake error: ~0p ~0p~n", [state.protocol, error, peername])
          end
        end)
    end

    do_accept(state, port)
  end

  defp start_worker!(state, cmd) do
    worker_state = %{
      server_pid: state.pid,
      ssl_opts: state.opts
    }

    {:ok, worker} =
      GenServer.start(state.protocol, {worker_state, cmd},
        hibernate_after: 5_000,
        timeout: 4_000
      )

    worker
  end

  def default_ssl_options(_opts) do
    w = Diode.miner()
    public = Wallet.pubkey_long!(w)
    private = Wallet.privkey!(w)
    cert = Secp256k1.selfsigned(private, public)

    [
      mode: :binary,
      packet: 2,
      cert: cert,
      cacerts: [cert],
      versions: [:"tlsv1.2"],
      verify: :verify_peer,
      verify_fun: {&check/3, nil},
      fail_if_no_peer_cert: true,
      # Requires client to advertise the same
      # openssl s_client -curves secp256k1 -connect localhost:41045 -showcerts -msg -servername local -tls1_2 -tlsextdebug
      eccs: [:secp256k1],
      active: false,
      reuseaddr: true,
      key: {:ECPrivateKey, Secp256k1.der_encode_private(private, public)},
      show_econnreset: true,
      nodelay: false,
      delay_send: true
    ]
  end
end
