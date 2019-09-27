defmodule Network.Handler do
  @callback ssl_options() :: []
  @callback do_init() :: any()
  @callback on_exit(any()) :: :ok

  @doc false
  defmacro __using__(_opts) do
    quote do
      use GenServer

      def init([:init, socket]) do
        {:ok, %{}, {:continue, [:init, socket]}}
      end

      def init([:connect, node_id, address, port]) do
        :io.format("Creating connect worker: #{Wallet.printable(node_id)},~p~n", [[address, port]])

        {:ok, %{}, {:continue, [:connect, node_id, address, port]}}
      end

      def handle_continue([:init, socket], %{}) do
        enter_loop(socket)
      end

      def handle_continue([:connect, node_id, address, port], %{}) do
        address =
          case address do
            bin when is_binary(bin) -> :erlang.binary_to_list(address)
            tup when is_tuple(tup) -> tup
          end

        {:ok, socket} = :ssl.connect(address, port, ssl_options(), 5000)
        remote_id = Wallet.from_pubkey(Certs.extract(socket))

        if node_id != nil and not Wallet.equal?(node_id, remote_id) do
          IO.puts(
            "Expected #{Wallet.printable(node_id)} different from found #{
              Wallet.printable(remote_id)
            }"
          )
        end

        enter_loop(socket)
      end

      defp enter_loop(socket) do
        remote_id = Wallet.from_pubkey(Certs.extract(socket))

        if Wallet.equal?(remote_id, Store.wallet()) do
          :io.format("Server: Rejecting self-connection~n")
          {:stop, :normal, %{}}
        else
          # register ensure this process is stored under the correct remote_id
          # and also ensure setops(active:true) is not sent before server.ex
          # finished the handshake
          {:ok, server_port} = GenServer.call(__MODULE__, {:register, remote_id})

          :ssl.setopts(socket, active: true)

          state = %{
            socket: socket,
            node_id: remote_id,
            server_port: server_port
          }

          do_init(state)
        end
      end
    end
  end
end
