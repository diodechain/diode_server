# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Network.Server do
  @moduledoc """
    General TLS socket server that ensures:
      * Secp256k1 handshakes
      * Identities on server and client
      * Self-signed certs on both of them

    Then it spawns client connection based on the protocol handler
  """
  use GenServer
  require Logger

  @type sslsocket() :: any()

  defstruct socket: nil, clients: %{}, protocol: nil, port: nil, opts: []

  @type t :: %Network.Server{
          socket: sslsocket,
          clients: Map.t(),
          protocol: atom(),
          port: integer(),
          opts: %{}
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

    {:ok, %Network.Server{socket: socket, protocol: protocolHandler, port: port, opts: opts},
     {:continue, :accept}}
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

  def handle_info(:accept, state) do
    do_accept(state)
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.split_with(state.clients, fn {_node_id, node_pid} -> node_pid == pid end) do
      {[{failed_node, _pid}], clients} ->
        state = %Network.Server{state | clients: Map.new(clients)}
        state.protocol.on_exit(failed_node)
        {:noreply, state}

      {[], _clients} ->
        :io.format("~0p Connection setup failed before register (~0p)~n", [
          state.protocol,
          {pid, reason}
        ])

        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    :io.format("~p unhandled info: ~0p~n", [state.protocol, msg])
    {:noreply, state}
  end

  def handle_call(:get_connections, _from, state) do
    {:reply, state.clients, state}
  end

  def handle_call({:ensure_node_connection, node_id, address, port}, _from, state) do
    case Map.get(state.clients, node_id) do
      nil ->
        worker = start_worker!(state, [:connect, node_id, address, port])
        {:reply, worker, state}

      client ->
        {:reply, client, state}
    end
  end

  def handle_call({:register, node_id}, {pid, _}, state) do
    case Map.get(state.clients, node_id) do
      nil ->
        :ok

      oldpid ->
        :io.format(
          "~p Handshake anomaly(2): #{Wallet.printable(node_id)} was already connected~n",
          [state.protocol]
        )

        Process.exit(oldpid, :disconnect)
    end

    clients = Map.put(state.clients, node_id, pid)
    {:reply, {:ok, state.port}, %{state | clients: clients}}
  end

  def handle_continue(:accept, state) do
    do_accept(state)
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

    send(self(), :accept)
    {:noreply, state}
  end

  defp start_worker!(state, cmd) do
    worker_state = %{
      server_pid: self(),
      ssl_opts: state.opts
    }

    {:ok, worker} =
      GenServer.start_link(state.protocol, {worker_state, cmd},
        hibernate_after: 5_000,
        timeout: 4_000
      )

    worker
  end

  def default_ssl_options(_opts) do
    w = Store.wallet()
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
      # openssl s_client -curves secp256k1 -connect localhost:41043 -showcerts -msg -servername local -tls1_2 -tlsextdebug
      eccs: [:secp256k1],
      active: false,
      reuseaddr: true,
      key: {:ECPrivateKey, Secp256k1.der_encode_private(private, public)}
    ]
  end
end
