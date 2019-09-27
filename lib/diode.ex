require Logger

defmodule Diode do
  use Application

  def start(_type, args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(PubSub, [args]),
      worker(Store, [args]),
      worker(Chain, [args]),
      worker(Chain.BlockCache, [args]),
      worker(Chain.Pool, [args]),
      worker(Chain.Worker, [workerMode()]),

      # Starting External Interfaces
      Supervisor.child_spec({Network.Server, {edgePort(), Network.EdgeHandler}}, id: EdgeServer),
      Supervisor.child_spec({Network.Server, {kademliaPort(), Network.PeerHandler}},
        id: KademliaServer
      ),
      worker(Kademlia, [args]),
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
      )
    ]

    IO.puts("====== ENV #{Mix.env()} ======")
    :persistent_term.put(:env, Mix.env())
    IO.puts("Edge Port: #{edgePort()}")
    IO.puts("Peer Port: #{kademliaPort()}")
    IO.puts("RPC  Port: #{rpcPort()}")
    IO.puts("")

    if dev_mode?() and [] == wallets() do
      wallets = for _n <- 1..5, do: Wallet.new()
      keys = Enum.map(wallets, fn w -> Base16.encode(Wallet.privkey!(w)) end)
      System.put_env("WALLETS", Enum.join(keys, " "))

      IO.puts("====== DEV Accounts ======")

      for w <- wallets do
        IO.puts("#{Wallet.printable(w)} priv #{Base16.encode(Wallet.privkey!(w))}")
      end
    else
      IO.puts("====== Accounts ======")

      for w <- wallets() do
        IO.puts("#{Wallet.printable(w)}")
      end
    end

    IO.puts("")

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
    env() == :dev or env() == :test
  end

  @spec test_mode? :: boolean
  def test_mode?() do
    env() == :test
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
    Hash.sha3_256(bin)
  end

  @spec miner() :: Wallet.t()
  def miner() do
    Store.wallet()
  end

  @spec wallets() :: [Wallet.t()]
  @doc """
    Decode env parameter such as
    export WALLETS="0x1234567890 0x987654321"
  """
  def wallets() do
    get_env("WALLETS", "")
    |> String.split(" ", trim: true)
    |> Enum.map(fn int ->
      decode_int(int)
      |> :binary.encode_unsigned()
      |> Wallet.from_privkey()
    end)

    # |> List.insert_at(0, miner())
  end

  def registryAddress() do
    Base16.decode("0x5000000000000000000000000000000000000000")
  end

  def fleetAddress() do
    Base16.decode("0x6000000000000000000000000000000000000000")
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
    hd(seeds())
  end

  def seeds() do
    get_env(
      "SEED",
      "diode://0x0ffc572a936a1e0ebf9c43aacb145d08847f0a1d@seed-alpha.diodechain.io:51053 " <>
        "diode://0x0ffc572a936a1e0ebf9c43aacb145d08847f0a1d@seed-beta.diodechain.io:51053 " <>
        "diode://0x0ffc572a936a1e0ebf9c43aacb145d08847f0a1d@seed-gamma.diodechain.io:51053"
    )
    |> String.split(" ", trim: true)
  end

  @spec workerMode() :: :disabled | :poll | integer()
  def workerMode() do
    case get_env("WORKER_MODE", "run") do
      "poll" -> :poll
      "disabled" -> :disabled
      _number -> get_env_int("WORKER_MODE", 75)
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

  def get_env_int(name, default) do
    decode_int(get_env(name, default))
  end

  defp decode_int(int) do
    case int do
      <<"0x", _::binary>> = bin ->
        Base16.decode_int(bin)

      bin when is_binary(bin) ->
        {num, _} = Integer.parse(bin)
        num

      int when is_integer(int) ->
        int
    end
  end
end
