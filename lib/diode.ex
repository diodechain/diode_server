require Logger

defmodule Diode do
  use Application

  def start(_type, args) do
    import Supervisor.Spec, warn: false

    children = [
      # Define workers and child supervisors to be supervised
      #      Plug.Adapters.Cowboy.child_spec(
      #        :https,
      #        Kademlia,
      #        [],
      #        port: ssl_port,
      #        otp_app: :kademlia,
      #        keyfile: "ssl/key.pem",
      #        certfile: "ssl/cer.pem"
      #        # cacertfile: "ssl/certs.pem",
      #      ),
      Plug.Adapters.Cowboy.child_spec(:http, Network.RpcHttp, [],
        ip: {127, 0, 0, 1},
        port: rpcPort(),
        dispatch: [
          {:_,
           [
             {"/ws", Network.RpcWs, []},
             {:_, Plug.Adapters.Cowboy.Handler, {Network.RpcHttp, []}}
           ]}
        ]
      ),
      worker(Store, [args]),
      Supervisor.child_spec({Network.Server, {edgePort(), Network.EdgeHandler}}, id: EdgeServer),
      Supervisor.child_spec({Network.Server, {kademliaPort(), Network.PeerHandler}},
        id: KademliaServer
      ),
      worker(Kademlia, [args]),
      worker(Chain, [args]),
      worker(Chain.BlockCache, [args]),
      worker(Chain.Pool, [args]),
      worker(Chain.Worker, [workerMode()])
    ]

    IO.puts("Edge Port: #{edgePort()}")
    IO.puts("Peer Port: #{kademliaPort()}")
    IO.puts("RPC  Port: #{rpcPort()}")

    :persistent_term.put(:env, Mix.env())

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    Supervisor.start_link(children, strategy: :one_for_one, name: Diode.Supervisor)
  end

  @spec env :: :prod | :test | :dev
  def env() do
    :persistent_term.get(:env)
  end

  @spec dev_mode? :: boolean
  def dev_mode?() do
    env() == :dev
  end

  @spec trace? :: boolean
  def trace?() do
    true == :persistent_term.get(:trace, false)
  end

  def trace(false) do
    :persistent_term.put(:trace, false)
  end

  def trace(true) do
    :persistent_term.put(:trace, true)
  end

  @spec hash(binary()) :: binary()
  def hash(bin) do
    # Ethereum is using KEC instead ...
    :crypto.hash(:sha256, bin)
  end

  @spec miner() :: Wallet.t()
  def miner() do
    get_config(:miner, Wallet.privkey!(Store.wallet()))
    |> Wallet.from_privkey()
  end

  @spec wallets() :: [Wallet.t()]
  def wallets() do
    other =
      get_config(:wallets, [])
      |> Enum.map(&Wallet.from_privkey/1)

    [miner() | other]
  end

  def registryAddress() do
    Base16.decode("0x5000000000000000000000000000000000000000")
  end

  @spec dataDir(binary()) :: binary()
  def dataDir(file \\ "") do
    get_env("DATA_DIR", File.cwd!() <> "/data/") <> file
  end

  def host() do
    get_env("HOST", fn ->
      {:ok, [{{a, b, c, d}, _b, _m} | _]} = :inet.getif()
      "#{a}.#{b}.#{c}.#{d}"
    end)
  end

  @spec rpcPort() :: integer()
  def rpcPort() do
    get_env_int("RPC_PORT", 8545)
  end

  @spec edgePort() :: integer()
  def edgePort() do
    get_env_int("EDGE_PORT", 41043)
  end

  @spec kademliaPort() :: integer()
  def kademliaPort() do
    get_env_int("KADEMLIA_PORT", 51053)
  end

  @spec seed() :: binary()
  def seed() do
    get_env(
      "SEED",
      "diode://0x0ffc572a936a1e0ebf9c43aacb145d08847f0a1d@seed-alpha.diodechain.io:51053"
    )
  end

  @spec workerMode() :: :disabled | :poll | integer()
  def workerMode() do
    case get_env("WORKER_MODE", "run") do
      "poll" -> :poll
      "disabled" -> :disabled
      _number -> get_env_int("WORKER_MODE", 1)
    end
  end

  def self() do
    Object.Server.new(host(), kademliaPort(), edgePort())
    |> Object.Server.sign(Wallet.privkey!(Store.wallet()))
  end

  defp get_env(name, default) do
    case System.get_env(name) do
      nil when is_function(default) -> default.()
      nil -> default
      other -> other
    end
  end

  defp get_env_int(name, default) do
    case get_env(name, default) do
      bin when is_binary(bin) ->
        {num, _} = Integer.parse(bin)
        num

      int when is_integer(int) ->
        int
    end
  end

  defp get_config(name, default) do
    case Application.fetch_env(Diode, name) do
      :error when is_function(default) -> default.()
      :error -> default
      {:ok, value} -> value
    end
  end
end
