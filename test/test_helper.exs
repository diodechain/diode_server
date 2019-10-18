ExUnit.start(seed: 0)

defmodule TestHelper do
  @delay_clone 10_000
  @cookie "EXTMP_K66"

  def reset() do
    Chain.reset_state()
    TicketStore.clear()
    Kademlia.reset()
    wait(0)
    Chain.Worker.work()
    wait(1)
  end

  def wait(n) do
    case Chain.block(n) do
      %Chain.Block{} ->
        :ok

      _other ->
        :io.format("Waiting for block ~p~n", [n])
        Process.sleep(100)
        wait(n)
    end
  end

  def kademliaPort(num) do
    10_001 + num * 3
  end

  def rpcPort(num) do
    10_002 + num * 3
  end

  def name_clone(n) do
    {:ok, name} = :inet.gethostname()
    String.to_atom("clone_#{n}@#{name}")
  end

  def start_clones(number) do
    kill_clones()
    :ok = wait_clones(0, 60)
    basedir = File.cwd!() <> "/clones"
    File.rm_rf!(basedir)
    File.mkdir!(basedir)

    for num <- 1..number do
      clonedir = "#{basedir}/#{num}"
      file = File.stream!("#{basedir}/#{num}.log")

      spawn_link(fn ->
        System.cmd(
          "iex",
          ["--cookie", @cookie, "-S", "mix", "run"],
          env: [
            {"DATA_DIR", clonedir},
            {"RPC_PORT", "#{rpcPort(num)}"},
            {"EDGE_PORT", "#{10_000 + num * 3}"},
            {"KADEMLIA_PORT", "#{kademliaPort(num)}"},
            {"SEED", "diode://localhost:#{kademliaPort(num)}"}
          ],
          stderr_to_stdout: true,
          into: file
        )
      end)

      Process.sleep(1000)
    end

    :ok = wait_clones(number, 60)
    Process.sleep(@delay_clone)
  end

  def wait_clones(_target_count, 0) do
    :error
  end

  def wait_clones(target_count, seconds) do
    {ret, _} = System.cmd("pgrep", ["-fc", @cookie])
    {count, _} = Integer.parse(ret)

    if count == target_count do
      :ok
    else
      Process.sleep(1000)
      wait_clones(target_count, seconds - 1)
    end
  end

  def kill_clones() do
    System.cmd("pkill", ["-fc", "-9", @cookie])
  end

  def wait_for(fun, comment, timeout \\ 10)

  def wait_for(_fun, comment, 0) do
    msg = "Failed to wait for #{comment}"
    IO.puts(msg)
    throw(msg)
  end

  def wait_for(fun, comment, timeout) do
    case fun.() do
      true ->
        :ok

      false ->
        IO.puts("Waiting for #{comment} t-#{timeout}")
        Process.sleep(100)
        wait_for(fun, comment, timeout - 1)
    end
  end

  def clientid(n) do
    Wallet.from_privkey(clientkey(n))
  end

  def clientkey(n) do
    Certs.private_from_file("./test/pems/device#{n}_certificate.pem")
  end
end
