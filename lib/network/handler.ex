# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Handler do
  @callback ssl_options([]) :: []
  @callback do_init() :: any()
  @callback on_nodeid(any()) :: any()

  @doc false
  defmacro __using__(_opts) do
    quote do
      use GenServer

      def init({state, :init}) do
        setup_process(state)
        {:ok, state, {:continue, :init}}
      end

      def init({state, [:connect, node_id, address, port]}) do
        setup_process(state)
        log({node_id, address}, "Creating connect worker")
        {:ok, state, {:continue, [:connect, node_id, address, port]}}
      end

      defp setup_process(state) do
        Process.link(state.server_pid)
        Process.flag(:max_heap_size, 25_000_000)
      end

      def handle_continue(:init, state) do
        socket =
          receive do
            {:init, socket} ->
              socket
          after
            5000 ->
              log(nil, "Socket continue timeout")
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

        case :ssl.connect(address, port, ssl_options(role: :client), 5000) do
          {:ok, socket} ->
            remote_id = Wallet.from_pubkey(Certs.extract(socket))

            if node_id != nil and not Wallet.equal?(node_id, remote_id) do
              log(
                {node_id, address, port},
                "Expected #{Wallet.printable(node_id)} different from found #{Wallet.printable(remote_id)}"
              )
            end

            if not Wallet.equal?(node_id, remote_id) do
              on_nodeid(remote_id)
            end

            enter_loop(Map.merge(state, %{socket: socket, address: address}))

          other ->
            log(
              {node_id, address, port},
              "Connection failed in ssl.connect(): ~p",
              [other]
            )

            {:stop, :normal, state}
        end
      end

      defp enter_loop(state = %{socket: socket, server_pid: server}) do
        with {:ok, info} <- :ssl.connection_information(socket),
             {:ok, {address, port}} <- :ssl.peername(socket),
             {:ok, cert} <- :ssl.peercert(socket),
             remote_id <- Wallet.from_pubkey(Certs.id_from_der(cert)),
             state <-
               Map.merge(state, %{
                 socket: socket,
                 node_id: remote_id,
                 node_address: address,
                 node_port: port,
                 server_port: nil
               }),

             # register ensure this process is stored under the correct remote_id
             # and also ensure setops(active:true) is not sent before server.ex
             # finished the handshake
             {:ok, server_port} <- GenServer.call(server, {:register, remote_id}),
             :ok <- set_keepalive(:os.type(), socket),
             :ok <- :ssl.setopts(socket, active: true) do
          state = Map.put(state, :server_port, server_port)
          do_init(state)
        else
          {:deny, _server_port} ->
            delay = Random.random(2500, 7500)
            log(state, "Server: Rejecting double-connection (delay #{delay})")
            Process.sleep(delay)
            {:stop, :normal, state}

          {:error, reason} ->
            log(nil, "Connection gone away ~p", [reason])
            {:stop, :normal, state}
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
      defp set_keepalive({:unix, :linux}, socket) do
        sol_socket = 1
        so_keepalive = 9

        ipproto_tcp = 6
        tcp_keepcnt = 6
        tcp_keepidle = 4
        tcp_keepintvl = 5

        with :ok <- set_tcpopt(socket, sol_socket, so_keepalive, 1),
             :ok <- set_tcpopt(socket, ipproto_tcp, tcp_keepcnt, 5),
             :ok <- set_tcpopt(socket, ipproto_tcp, tcp_keepidle, 60),
             :ok <- set_tcpopt(socket, ipproto_tcp, tcp_keepintvl, 60) do
          :ok
        end
      end

      defp set_keepalive(_other, socket) do
        :ssl.setopts(socket, [{:keepalive, true}])
      end

      defp set_tcpopt(socket, level, opt, value) do
        :ssl.setopts(socket, [{:raw, level, opt, <<value::unsigned-little-size(32)>>}])
      end

      def name(%{node_id: node_id, address: node_address})
          when node_address != nil do
        name({node_id, node_address})
      end

      def name(%{node_id: node_id, node_address: node_address}) do
        name({node_id, node_address})
      end

      def name(%{server_pid: _pid}) do
        "pre_connection_information"
      end

      def name({node_id, node_address, _port}) do
        name({node_id, node_address})
      end

      def name({_node_id, node_address}) do
        case node_address do
          tuple when is_tuple(tuple) -> List.to_string(:inet.ntoa(tuple))
          other -> other
        end
      end

      def name(nil) do
        "nil"
      end

      def log(state, format, args \\ []) do
        mod = List.last(Module.split(__MODULE__))
        date = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> to_string()
        :io.format("~s ~s: ~s ~s~n", [date, mod, name(state), format(format, args)])
      end

      defp format(format, []), do: format

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
