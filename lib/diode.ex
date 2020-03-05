# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
require Logger

defmodule Diode do
  use Application

  def start(_type, args) do
    import Supervisor.Spec, warn: false

    if travis_mode?() do
      puts("++++++ TRAVIS DETECTED ++++++")
      puts("~0p~n", [:inet.getifaddrs()])
      puts("~0p~n", [:inet.get_rc()])
      puts("~0p~n", [:inet.getaddr('localhost', :inet)])
      puts("~0p~n", [:inet.gethostname()])
    end

    :persistent_term.put(:env, Mix.env())
    puts("====== ENV #{Mix.env()} ======")
    puts("Edge Port: #{edgePort()}")
    puts("Peer Port: #{peerPort()}")
    puts("RPC  Port: #{rpcPort()}")
    puts("Data Dir : #{data_dir()}")
    puts("")

    if dev_mode?() and [] == wallets() do
      wallets =
        for n <- 1..5, do: Wallet.from_privkey(Hash.keccak_256("#{Date.utc_today()}.#{n}"))

      keys = Enum.map(wallets, fn w -> Base16.encode(Wallet.privkey!(w)) end)
      System.put_env("WALLETS", Enum.join(keys, " "))

      puts("====== DEV Accounts ==")

      for w <- wallets do
        puts("#{Wallet.printable(w)} priv #{Base16.encode(Wallet.privkey!(w))}")
      end
    else
      puts("====== Accounts ======")

      for w <- wallets() do
        puts("#{Wallet.printable(w)}")
      end
    end

    puts("")

    base_children = [
      supervisor(Model.Sql, []),
      worker(PubSub, [args]),
      worker(Model.CredSql, [args]),
      worker(Chain.BlockCache, [args]),
      worker(Chain, [args]),
      worker(Chain.Pool, [args]),
      worker(Chain.Worker, [worker_mode()])
    ]

    children =
      if Mix.env() == :benchmark do
        base_children
      else
        {:ok, _pid} = rpc_api(:http, port: rpcPort())

        if not dev_mode?() do
          start_ssl()
        end

        network_children = [
          # Starting External Interfaces
          Network.Server.child(edgePort(), Network.EdgeHandler),
          Network.Server.child(peerPort(), Network.PeerHandler),
          worker(Kademlia, [args])
        ]

        base_children ++ network_children
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Diode.Supervisor)
  end

  def puts(string, format \\ []) do
    if not test_mode?(), do: :io.format("#{string}~n", format)
  end

  defp rpc_api(scheme, opts) do
    apply(Plug.Cowboy, scheme, [
      Network.RpcHttp,
      [],
      [
        ip: {0, 0, 0, 0},
        compress: not Diode.dev_mode?(),
        dispatch: [
          {:_,
           [
             {"/ws", Network.RpcWs, []},
             {:_, Plug.Adapters.Cowboy.Handler, {Network.RpcHttp, []}}
           ]}
        ]
      ] ++ opts
    ])
  end

  defp start_ssl() do
    case File.read("priv/privkey.pem") do
      {:ok, _} ->
        puts("++++++  SSL ON  ++++++")
        puts("RPC  SSL Port: #{rpcsPort()}")
        puts("")

        rpc_api(:https,
          keyfile: "priv/privkey.pem",
          certfile: "priv/cert.pem",
          cacertfile: "priv/fullchain.pem",
          port: rpcsPort(),
          otp_app: Diode
        )

      _ ->
        []
    end
  end

  @spec env :: :prod | :test | :dev
  def env() do
    :persistent_term.get(:env)
  end

  def chain_id() do
    41043
  end

  @spec dev_mode? :: boolean
  def dev_mode?() do
    env() == :dev or env() == :test
  end

  def travis_mode?() do
    case System.get_env("TRAVIS", nil) do
      nil -> false
      _ -> true
    end
  end

  @spec test_mode? :: boolean
  def test_mode?() do
    env() == :test
  end

  @spec trace? :: boolean
  def trace?() do
    true == :persistent_term.get(:trace, false)
  end

  @spec trace(boolean) :: any
  def trace(enabled) when is_boolean(enabled) do
    :persistent_term.put(:trace, enabled)
  end

  @doc "Number of bytes the server is willing to send without payment yet."
  def ticket_grace() do
    :persistent_term.get(:ticket_grace, 1024 * 40960)
  end

  def ticket_grace(bytes) when is_integer(bytes) do
    :persistent_term.put(:ticket_grace, bytes)
  end

  @spec hash(binary()) :: binary()
  def hash(bin) do
    # Ethereum is using KEC instead ...
    Hash.sha3_256(bin)
  end

  @spec miner() :: Wallet.t()
  def miner() do
    Model.CredSql.wallet()
  end

  def syncing?() do
    Process.whereis(:active_sync) != nil
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

  @spec data_dir(binary()) :: binary()
  def data_dir(file \\ "") do
    get_env("DATA_DIR", File.cwd!() <> "/data_" <> Atom.to_string(env()) <> "/") <> file
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

  def rpcsPort() do
    get_env_int("RPCS_PORT", 8443)
  end

  @spec edgePort() :: integer()
  def edgePort() do
    get_env_int("EDGE_PORT", 41045)
  end

  @spec peerPort() :: integer()
  def peerPort() do
    get_env_int("PEER_PORT", 51054)
  end

  def seeds() do
    get_env(
      "SEED",
      "diode://0x68e0bafdda9ef323f692fc080d612718c941d120@seed-alpha.diode.io:51054 " <>
        "diode://0x937c492a77ae90de971986d003ffbc5f8bb2232c@seed-beta.diode.io:51054 " <>
        "diode://0xceca2f8cf1983b4cf0c1ba51fd382c2bc37aba58@seed-gamma.diode.io:51054"
    )
    |> String.split(" ", trim: true)
    |> Enum.reject(fn item -> item == "none" end)
  end

  @spec worker_mode() :: :disabled | :poll | integer()
  def worker_mode() do
    case get_env("WORKER_MODE", "run") do
      "poll" -> :poll
      "disabled" -> :disabled
      _number -> get_env_int("WORKER_MODE", 75)
    end
  end

  def self(), do: self(host())

  def self(hostname) do
    Object.Server.new(hostname, peerPort(), edgePort())
    |> Object.Server.sign(Wallet.privkey!(Diode.miner()))
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
      "" ->
        0

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
