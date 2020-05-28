# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
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

  defstruct socket: nil,
            clients: %{},
            protocol: nil,
            port: nil,
            opts: [],
            pid: nil,
            acceptor: nil,
            self_conns: []

  @type t :: %Network.Server{
          socket: sslsocket,
          clients: Map.t(),
          protocol: atom(),
          port: integer(),
          opts: %{},
          acceptor: pid() | nil,
          pid: pid(),
          self_conns: []
        }

  def start_link({port, protocolHandler, opts}) do
    GenServer.start_link(__MODULE__, {port, protocolHandler, opts}, name: opts.name)
  end

  def child(port, protocolHandler, opts \\ []) do
    opts =
      %{name: protocolHandler}
      |> Map.merge(Map.new(opts))

    Supervisor.child_spec({__MODULE__, {port, protocolHandler, opts}}, id: opts.name)
  end

  @spec init({integer(), atom(), %{}}) :: {:ok, Network.Server.t(), {:continue, :accept}}
  def init({port, protocolHandler, opts}) do
    :erlang.process_flag(:trap_exit, true)
    {:ok, socket} = :ssl.listen(port, protocolHandler.ssl_options(opts))

    {:ok,
     %Network.Server{
       socket: socket,
       protocol: protocolHandler,
       port: port,
       opts: opts,
       pid: self()
     }, {:continue, :accept}}
  end

  def check(_cert, event, state) do
    case event do
      {:bad_cert, :selfsigned_peer} -> {:valid, state}
      _ -> {:fail, event}
    end
  end

  def get_connections(name) do
    GenServer.call(name, :get_connections)
  end

  def ensure_node_connection(name, node_id, address, port) do
    GenServer.call(name, {:ensure_node_connection, node_id, address, port})
  end

  def handle_info({:EXIT, pid, reason}, state = %{acceptor: pid}) do
    :io.format("~p acceptor crashed ~p~n", [state.protocol, reason])
    acceptor = spawn_link(fn -> do_accept(state) end)
    {:noreply, %{state | acceptor: acceptor}}
  end

  def handle_info({:EXIT, pid, reason}, state = %{clients: clients}) do
    case Map.get(clients, pid) do
      nil ->
        :io.format("~0p Connection setup failed before register (~0p)~n", [
          state.protocol,
          {pid, reason}
        ])

        {:noreply, state}

      key ->
        clients = Map.drop(clients, [pid, key])
        {:noreply, %{state | clients: clients}}
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

  def handle_call(:get_connections, _from, state) do
    result =
      Enum.filter(state.clients, fn {_key, value} ->
        is_pid(value)
      end)
      |> Map.new()

    {:reply, result, state}
  end

  def handle_call({:ensure_node_connection, node_id, address, port}, _from, state) do
    if Wallet.equal?(Diode.miner(), node_id) do
      if state.self_conns != [] do
        {:reply, hd(state.self_conns), state}
      else
        worker = start_worker!(state, [:connect, node_id, "localhost", Diode.peer_port()])
        {:reply, worker, %{state | self_conns: [worker]}}
      end
    else
      key = to_key(node_id)

      case Map.get(state.clients, key) do
        nil ->
          worker = start_worker!(state, [:connect, node_id, address, port])

          clients =
            Map.put(state.clients, key, worker)
            |> Map.put(worker, key)

          {:reply, worker, %{state | clients: clients}}

        client ->
          {:reply, client, state}
      end
    end
  end

  def handle_call({:register, node_id}, {pid, _}, state) do
    if Wallet.equal?(Diode.miner(), node_id) do
      state = %{state | self_conns: [pid | state.self_conns]}
      {:reply, {:ok, state.port}, state}
    else
      register_node(node_id, pid, state)
    end
  end

  defp register_node(node_id, pid, state) do
    # Checking whether pid is already registered and needs an update
    clients =
      case Map.get(state.clients, pid) do
        nil -> state.clients
        key -> Map.delete(state.clients, key)
      end

    key = to_key(node_id)

    # Checking whether node_id is already registered
    case Map.get(clients, key) do
      nil ->
        :ok

      ^pid ->
        :ok

      other_pid ->
        :io.format(
          "~p Handshake anomaly(~p): #{Wallet.printable(node_id)} was already connected: ~180p~n",
          [state.protocol, pid, {other_pid, Process.alive?(other_pid)}]
        )

        Process.exit(other_pid, :disconnect)

        receive do
          {:EXIT, ^other_pid, :disconnect} ->
            :ok

          {:EXIT, ^other_pid, other_reason} ->
            :io.format("~p process exited for unexpected reason: ~p~n", [
              state.protocol,
              other_reason
            ])
        after
          500 ->
            if Process.alive?(other_pid) do
              throw(:inconsistent_process)
            else
              :io.format("~p process exited without reason~n", [state.protocol])
            end
        end
    end

    clients =
      Map.put(clients, key, pid)
      |> Map.put(pid, key)

    {:reply, {:ok, state.port}, %{state | clients: clients}}
  end

  def handle_continue(:accept, state) do
    acceptor = spawn_link(fn -> do_accept(state) end)
    {:noreply, %{state | acceptor: acceptor}}
  end

  defp do_accept(state) do
    case :ssl.transport_accept(state.socket, 100) do
      {:error, :timeout} ->
        # This timeout is to yield to standard gen_server behaviour
        :ok

      {:error, :closed} ->
        # Connection abort before handshake
        :io.format("~p Anomaly - Connection closed before TLS handshake~n", [state.protocol])

      {:ok, newSocket} ->
        case :ssl.handshake(newSocket) do
          {:ok, newSocket2} ->
            worker = start_worker!(state, :init)
            :ok = :ssl.controlling_process(newSocket2, worker)
            send(worker, {:init, newSocket2})

          {:error, error} ->
            :io.format("~p Handshake error: ~0p~n", [state.protocol, error])
        end
    end

    do_accept(state)
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
