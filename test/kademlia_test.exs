defmodule KademliaTest do
  use ExUnit.Case, async: true
  alias Network.Server, as: Server
  alias Network.PeerHandler, as: PeerHandler

  # Need bigger number to have a not connected network
  # 30
  @network_size 2
  # 10_000
  @delay 10_000

  test "connect" do
    conns = Server.get_connections(PeerHandler)
    # :io.format("~p~n", [conns])

    assert Map.size(conns) == 0

    for n <- 1..@network_size do
      pid = Server.ensure_node_connection(PeerHandler, nil, "localhost", kademliaPort(n))
      assert GenServer.call(pid, :ping) == :pong
      assert Map.size(Server.get_connections(PeerHandler)) == n
    end

    # network = GenServer.call(Kademlia, :get_network)
    # :io.format("~p~n", [KBuckets.size(network)])
    # assert KBuckets.size(network) == n + 1
  end

  test "send/receive" do
    values = Enum.map(1..100, fn idx -> {"#{idx}", "value_#{idx}"} end)

    for {key, value} <- values do
      Kademlia.store(key, value)
    end

    for {key, value} <- values do
      assert Kademlia.find_value(key) == value
    end

    for {key, _value} <- values do
      assert Kademlia.find_value("not_#{key}") == nil
    end
  end

  setup_all do
    IO.puts("Starting clones")
    start_clones(@network_size)

    on_exit(fn ->
      IO.puts("Killing clones")
      kill_clones()
    end)
  end

  def kademliaPort(num) do
    10001 + num * 3
  end

  def start_clones(number) do
    kill_clones()
    :ok = wait(0, 60)

    basedir = File.cwd!() <> "/clones"
    File.mkdir_p!(basedir)

    for num <- 1..number do
      clonedir = "#{basedir}/#{num}"
      file = File.stream!("#{basedir}/#{num}.log")

      spawn_link(fn ->
        System.cmd("iex", ["--cookie", "EXTMP_K66", "-S", "mix", "run"],
          env: [
            {"DATA_DIR", clonedir},
            {"RPC_PORT", "#{10002 + num * 3}"},
            {"EDGE_PORT", "#{10000 + num * 3}"},
            {"KADEMLIA_PORT", "#{kademliaPort(num)}"},
            {"SEED", "diode://localhost:#{kademliaPort(num)}"}
          ],
          stderr_to_stdout: true,
          into: file
        )
      end)

      Process.sleep(1000)
    end

    :ok = wait(number, 60)
    Process.sleep(@delay)
  end

  def wait(_target_count, 0) do
    :error
  end

  def wait(target_count, seconds) do
    {ret, _} = System.cmd("pgrep", ["-fc", "EXTMP_K66"])
    {count, _} = Integer.parse(ret)

    if count == target_count do
      :ok
    else
      Process.sleep(1000)
      wait(target_count, seconds - 1)
    end
  end

  def kill_clones() do
    System.cmd("pkill", ["-fc", "-9", "EXTMP_K66"])
  end
end
