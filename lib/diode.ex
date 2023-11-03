# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
require Logger

defmodule Diode do
  use Application

  # Ignoring all info level sasl messages
  def filter_function(event, _) do
    case event do
      %{level: :info, meta: %{domain: [:otp, :sasl]}} -> :stop
      _other -> :ignore
    end
  end

  def start(_type, args) do
    :persistent_term.put(:env, Mix.env())
    :erlang.system_flag(:backtrace_depth, 30)
    :logger.add_primary_filter(:ignore_supervisor_infos, {&filter_function/2, []})

    set_chaindefinition()

    if travis_mode?() do
      puts("++++++ TRAVIS DETECTED ++++++")
      puts("~0p~n", [:inet.getifaddrs()])
      puts("~0p~n", [:inet.get_rc()])
      puts("~0p~n", [:inet.getaddr('localhost', :inet)])
      puts("~0p~n", [:inet.gethostname()])
    end

    puts("====== ENV #{Mix.env()} ======")
    puts("Build       : #{version()}")
    puts("Edge    Port: #{Enum.join(edge2_ports(), ",")}")
    puts("Peer    Port: #{peer_port()}")
    puts("RPC     Port: #{rpc_port()}")

    if ssl?() do
      puts("RPC SSL Port: #{rpcs_port()}")
    else
      puts("RPC SSL Port: DISABLED")
    end

    puts("Data Dir : #{data_dir()}")

    if System.get_env("COOKIE") do
      :erlang.set_cookie(String.to_atom(System.get_env("COOKIE")))
      puts("Cookie   : #{System.get_env("COOKIE")}")
    end

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

    ets_extra =
      if memory_mode() == :minimal do
        [:compressed]
      else
        []
      end

    base_children = [
      worker(Stats, []),
      supervisor(Model.Sql),
      supervisor(Channels),
      supervisor(Moonbeam.Sup),
      worker(Chain.BlockCache, [ets_extra]),
      worker(Chain, [ets_extra]),
      worker(PubSub, [args]),
      worker(Chain.Pool, [args]),
      worker(TicketStore, [ets_extra])
    ]

    children =
      if Mix.env() == :benchmark do
        base_children
      else
        network_children = [
          # Starting External Interfaces
          Network.Server.child(peer_port(), Network.PeerHandler),
          worker(Kademlia, [args]),
          worker(Stages)
        ]

        base_children ++ network_children
      end

    children = children ++ [worker(Chain.Worker, [worker_mode()])]
    Supervisor.start_link(children, strategy: :rest_for_one, name: Diode.Supervisor)
  end

  # To be started from the stage gen_server
  def start_client_network() do
    rpc_api(:http, port: rpc_port())

    if not dev_mode?() do
      ssl_rpc_api()
    end

    Supervisor.start_child(Diode.Supervisor, Network.Server.child(edge2_ports(), Network.EdgeV2))
    |> case do
      {:error, :already} -> Supervisor.restart_child(Diode.Supervisor, Network.EdgeV2)
      other -> other
    end
  end

  def stop_client_network() do
    Plug.Cowboy.shutdown(Network.RpcHttp.HTTP)
    Plug.Cowboy.shutdown(Network.RpcHttp.HTTPS)
    Supervisor.terminate_child(Diode.Supervisor, Network.EdgeV2)
  end

  defp set_chaindefinition() do
    def =
      cond do
        get_env("CHAINDEF") != nil ->
          "Elixir.ChainDefinition.#{get_env("CHAINDEF") |> String.capitalize()}"
          |> String.to_atom()

        Diode.dev_mode?() ->
          ChainDefinition.Devnet

        true ->
          ChainDefinition.Mainnet
      end

    :persistent_term.put(:chain_definition, def)
  end

  defp worker(module, args \\ []) do
    %{id: module, start: {Diode, :start_worker, [module, args]}}
  end

  defp supervisor(module, args \\ []) do
    %{
      id: module,
      start: {Diode, :start_worker, [module, args]},
      shutdown: :infinity,
      type: :supervisor
    }
  end

  def start_worker(module, args) do
    puts("Starting #{module}...")
    {t, ret} = :timer.tc(module, :start_link, args)
    puts("=======> #{module} loaded after #{Float.round(t / 1_000_000, 3)}s")
    ret
  end

  def start_subwork(label, fun) do
    puts("  #{label}...")
    {t, ret} = :timer.tc(fun)
    puts("  done #{label} after #{Float.round(t / 1_000_000, 3)}s")
    ret
  end

  def puts(string, format \\ []) do
    if not test_mode?(), do: :io.format("#{string}~n", format)
  end

  defp rpc_api(scheme, opts) do
    puts("Starting rpc_#{scheme}...")

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
             {:_, Plug.Cowboy.Handler, {Network.RpcHttp, []}}
           ]}
        ]
      ] ++ opts
    ])
  end

  defp ssl?() do
    case File.read("priv/privkey.pem") do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp ssl_rpc_api() do
    if ssl?() do
      rpc_api(:https,
        keyfile: "priv/privkey.pem",
        certfile: "priv/cert.pem",
        cacertfile: "priv/fullchain.pem",
        port: rpcs_port(),
        otp_app: Diode
      )
    end
  end

  @spec env :: :prod | :test | :dev
  def env() do
    :persistent_term.get(:env)
  end

  @spec chain_id :: non_neg_integer()
  def chain_id(block_number \\ Chain.peak()) do
    ChainDefinition.chain_id(block_number)
  end

  @version Mix.Project.config()[:full_version]
  def version() do
    "Diode Server #{@version}"
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
    :persistent_term.get(:ticket_grace, 1024 * 40_960)
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

  def registry_address() do
    Base16.decode("0x5000000000000000000000000000000000000000")
  end

  def fleet_address() do
    Base16.decode("0x6000000000000000000000000000000000000000")
  end

  @spec data_dir(binary()) :: binary()
  def data_dir(file \\ "") do
    get_env("DATA_DIR", File.cwd!() <> "/data_" <> Atom.to_string(env()) <> "/") <> file
  end

  def host() do
    get_env("HOST", fn ->
      {:ok, interfaces} = :inet.getif()
      ips = Enum.map(interfaces, fn {ip, _b, _m} -> ip end)

      {a, b, c, d} =
        Enum.find(ips, hd(ips), fn ip ->
          case ip do
            {127, _, _, _} -> false
            {10, _, _, _} -> false
            {192, 168, _, _} -> false
            {172, b, _, _} when b >= 16 and b < 32 -> false
            _ -> true
          end
        end)

      "#{a}.#{b}.#{c}.#{d}"
    end)
  end

  @spec rpc_port() :: integer()
  def rpc_port() do
    get_env_int("RPC_PORT", 8545)
  end

  def rpcs_port() do
    get_env_int("RPCS_PORT", 8443)
  end

  @spec edge2_ports :: [integer()]
  def edge2_ports() do
    get_env("EDGE2_PORT", "41046,443,993,1723,10000")
    |> String.trim()
    |> String.split(",")
    |> Enum.map(fn port -> decode_int(String.trim(port)) end)
  end

  @spec peer_port() :: integer()
  def peer_port() do
    get_env_int("PEER_PORT", 51054)
  end

  def seeds() do
    case get_env("SEED") do
      nil ->
        [
          "diode://0xceca2f8cf1983b4cf0c1ba51fd382c2bc37aba58@us1.prenet.diode.io:51054",
          "diode://0x7e4cd38d266902444dc9c8f7c0aa716a32497d0b@us2.prenet.diode.io:51054",
          "diode://0x68e0bafdda9ef323f692fc080d612718c941d120@as1.prenet.diode.io:51054",
          "diode://0x1350d3b501d6842ed881b59de4b95b27372bfae8@as2.prenet.diode.io:51054",
          "diode://0x937c492a77ae90de971986d003ffbc5f8bb2232c@eu1.prenet.diode.io:51054",
          "diode://0xae699211c62156b8f29ce17be47d2f069a27f2a6@eu2.prenet.diode.io:51054"
        ]

      other ->
        other
        |> String.split(" ", trim: true)
        |> Enum.reject(fn item -> item == "none" end)
    end
  end

  @spec worker_mode() :: :disabled | :poll | integer()
  def worker_mode() do
    case get_env("WORKER_MODE", "run") do
      "poll" -> :poll
      "disabled" -> :disabled
      _number -> get_env_int("WORKER_MODE", 75)
    end
  end

  @spec memory_mode() :: :normal | :minimal
  def memory_mode() do
    case get_env("MEMORY_MODE", "normal") do
      "normal" ->
        :normal

      "minimal" ->
        :minimal

      mode ->
        puts("Received unkown MEMORY_MODE #{mode}")
        :normal
    end
  end

  def self(), do: self(host())

  def self(hostname) do
    Object.Server.new(hostname, hd(edge2_ports()), peer_port(), version(), [
      ["tickets", TicketStore.value(Chain.epoch())],
      ["uptime", Diode.uptime()],
      ["block", Chain.peak()]
    ])
    |> Object.Server.sign(Wallet.privkey!(Diode.miner()))
  end

  def get_env(name, default \\ nil) do
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

  def uptime() do
    {uptime, _} = :erlang.statistics(:wall_clock)
    uptime
  end
end
