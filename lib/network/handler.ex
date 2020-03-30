# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Network.Handler do
  @callback ssl_options([]) :: []
  @callback do_init() :: any()
  @callback on_nodeid(any()) :: any()

  @doc false
  defmacro __using__(_opts) do
    quote do
      use GenServer

      def init({state, :init}) do
        Process.link(state.server_pid)
        {:ok, state, {:continue, :init}}
      end

      def init({state, [:connect, node_id, address, port]}) do
        Process.link(state.server_pid)
        log({node_id, address}, "Creating connect worker")
        {:ok, state, {:continue, [:connect, node_id, address, port]}}
      end

      def handle_continue(:init, state) do
        socket =
          receive do
            {:init, socket} ->
              socket
          after
            5000 ->
              log({nil, nil}, "Socket continue timeout")
              {:stop, :normal, state}
          end

        on_nodeid(Wallet.from_pubkey(Certs.extract(socket)))
        enter_loop(Map.put(state, :socket, socket))
      end

      def handle_continue([:connect, node_id, address, port], state) do
        on_nodeid(node_id)

        address =
          case address do
            bin when is_binary(bin) -> :erlang.binary_to_list(address)
            tup when is_tuple(tup) -> tup
          end

        case :ssl.connect(address, port, ssl_options(state.ssl_opts), 5000) do
          {:ok, socket} ->
            remote_id = Wallet.from_pubkey(Certs.extract(socket))

            if node_id != nil and not Wallet.equal?(node_id, remote_id) do
              log(
                {node_id, address},
                "Expected #{Wallet.printable(node_id)} different from found #{
                  Wallet.printable(remote_id)
                }"
              )

              on_nodeid(remote_id)
            end

            enter_loop(Map.put(state, :socket, socket))

          other ->
            log(
              {node_id, address},
              "Connection failed in ssl.connect(): ~p",
              [other]
            )

            {:stop, :normal, state}
        end
      end

      defp enter_loop(state = %{socket: socket, server_pid: server}) do
        case :ssl.connection_information(socket) do
          {:error, reason} ->
            log({nil, nil}, "Connection gone away ~p", [reason])
            {:stop, :normal, state}

          {:ok, info} ->
            {:ok, {address, _port}} = :ssl.peername(socket)
            remote_id = Wallet.from_pubkey(Certs.extract(socket))

            state = %{
              socket: socket,
              node_id: remote_id,
              node_address: address,
              server_port: nil
            }

            if Wallet.equal?(remote_id, Diode.miner()) do
              log(state, "Server: Rejecting self-connection~n")
              {:stop, :normal, state}
            else
              # register ensure this process is stored under the correct remote_id
              # and also ensure setops(active:true) is not sent before server.ex
              # finished the handshake
              case GenServer.call(server, {:register, remote_id}) do
                {:deny, _server_port} ->
                  log(state, "Server: Rejecting double-connection~n")
                  {:stop, :normal, state}

                {:ok, server_port} ->
                  set_keepalive(socket)
                  :ssl.setopts(socket, active: true)

                  state = Map.put(state, :server_port, server_port)
                  do_init(state)
              end
            end
        end
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

      def name(%{node_id: node_id, node_address: node_address}) do
        name({node_id, node_address})
      end

      def name({node_id, node_address}) do
        :io_lib.format("~s @ ~0p", [Wallet.nick(node_id), node_address])
      end

      def log(state, format, args \\ []) do
        mod = List.last(Module.split(__MODULE__))
        :io.format("~p ~s: ~s: ~s~n", [self(), mod, name(state), format(format, args)])
      end

      defp format(format, vars) do
        string = :io_lib.format(format, vars) |> :erlang.iolist_to_binary()

        if byte_size(string) > 180 do
          binary_part(string, 0, 180)
        else
          string
        end
      end
    end
  end
end
