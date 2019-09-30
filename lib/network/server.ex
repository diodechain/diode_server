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

  defstruct socket: nil, clients: %{}, protocol: nil, port: nil
  @type t :: %Network.Server{socket: sslsocket, clients: Map.t(), protocol: atom()}

  @spec start_link({integer(), atom()}) :: {:error, any()} | {:ok, pid()}
  def start_link({port, protcolHandler}) do
    GenServer.start_link(__MODULE__, {port, protcolHandler}, name: protcolHandler)
  end

  @spec init({integer(), atom()}) :: {:ok, Network.Server.t(), {:continue, :accept}}
  def init({port, protocolHandler}) do
    :erlang.process_flag(:trap_exit, true)

    {:ok, socket} = :ssl.listen(port, protocolHandler.ssl_options())

    {:ok, %Network.Server{socket: socket, protocol: protocolHandler, port: port},
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
        :io.format("~p Connection to failed (~p)~n", [state.protocol, {pid, reason}])
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    :io.format("~p unhandled info: ~180p~n", [__MODULE__, msg])
    {:noreply, state}
  end

  def handle_call(:get_connections, _from, state) do
    {:reply, state.clients, state}
  end

  def handle_call({:ensure_node_connection, node_id, address, port}, _from, state) do
    case Map.get(state.clients, node_id) do
      nil ->
        {:ok, worker} = GenServer.start_link(state.protocol, [:connect, node_id, address, port])
        {:reply, worker, state}

      client ->
        {:reply, client, state}
    end
  end

  def handle_call({:register, node_id}, {pid, _}, state) do
    state = %Network.Server{state | clients: Map.put(state.clients, node_id, pid)}
    {:reply, {:ok, state.port}, state}
  end

  def handle_continue(:accept, state) do
    do_accept(state)
  end

  defp do_accept(state) do
    state2 =
      case :ssl.transport_accept(state.socket, 100) do
        {:error, :timeout} ->
          # This timeout is to yield to standard gen_server behaviour
          state

        {:ok, newSocket} ->
          case :ssl.handshake(newSocket) do
            {:ok, newSocket2} ->
              node_id = Wallet.from_pubkey(Certs.extract(newSocket2))

              case Map.get(state.clients, node_id) do
                nil ->
                  false

                pid ->
                  IO.puts("Handshake anomaly: #{Wallet.printable(node_id)} was already connected")
                  Process.exit(pid, :disconnect)
              end

              {:ok, worker} = GenServer.start_link(state.protocol, [:init, newSocket2])

              set_keepalive(newSocket2)
              :ok = :ssl.controlling_process(newSocket2, worker)
              %Network.Server{state | clients: Map.put(state.clients, node_id, worker)}

            {:error, error} ->
              IO.puts("handshake error: #{inspect(error)}")
              state
          end
      end

    send(self(), :accept)
    {:noreply, state2}
  end

  # 4.2. The setsockopt function call
  #
  #   All you need to enable keepalive for a specific socket is to set the specific socket option on the socket itself.
  #   The prototype of the function is as follows:
  #
  #   int setsockopt(int s, int level, int optname,
  #                   const void *optval, socklen_t optlen)
  #
  #   The first parameter is the socket, previously created with the socket(2); the second one must be
  #   SOL_SOCKET, and the third must be SO_KEEPALIVE . The fourth parameter must be a boolean integer value, indicating
  #   that we want to enable the option, while the last is the size of the value passed before.
  #
  #   According to the manpage, 0 is returned upon success, and -1 is returned on error (and errno is properly set).
  #
  #   There are also three other socket options you can set for keepalive when you write your application. They all use
  #   the SOL_TCP level instead of SOL_SOCKET, and they override system-wide variables only for the current socket. If
  #   you read without writing first, the current system-wide parameters will be returned.
  #
  #   TCP_KEEPCNT: the number of unacknowledged probes to send before considering the connection dead and notifying the
  #   application layer
  #
  #   TCP_KEEPIDLE: the interval between the last data packet sent (simple ACKs are not considered data) and the first
  #   keepalive probe; after the connection is marked to need keepalive, this counter is not used any further
  #
  #   TCP_KEEPINTVL: the interval between subsequential keepalive probes, regardless of what the connection has
  #   exchanged in the meantime
  defp set_keepalive(socket) do
    tcp_keepcnt = 6
    tcp_keepidle = 4
    tcp_keepintvl = 5

    :ok = :ssl.setopts(socket, [{:keepalive, true}])
    :ok = set_tcpopt(socket, tcp_keepcnt, 5)
    :ok = set_tcpopt(socket, tcp_keepidle, 360)
    :ok = set_tcpopt(socket, tcp_keepintvl, 60)
    :ok
  end

  defp set_tcpopt(socket, opt, value) do
    ipproto_tcp = 6
    :ssl.setopts(socket, [{:raw, ipproto_tcp, opt, <<value::unsigned-size(32)>>}])
  end

  def default_ssl_options() do
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
