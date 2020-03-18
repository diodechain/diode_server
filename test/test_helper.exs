# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
ExUnit.start(seed: 0)

defmodule TestHelper do
  @delay_clone 10_000
  @cookie "EXTMP_K66"
  @max_ports 10

  def reset() do
    kill_clones()
    Chain.Pool.flush()
    Supervisor.terminate_child(Diode.Supervisor, Chain.Worker)
    Chain.reset_state()
    TicketStore.clear()
    Kademlia.reset()
    wait(0)
    Supervisor.restart_child(Diode.Supervisor, Chain.Worker)
    Chain.Worker.work()
    wait(1)
  end

  def wait(n) do
    case Chain.peak() >= n do
      true ->
        :ok

      false ->
        :io.format("Waiting for block ~p/~p~n", [n, Chain.peak()])
        Process.sleep(1000)
        wait(n)
    end
  end

  def edge_port(num) do
    20000 + num * @max_ports
  end

  def edge2_port(num) do
    20004 + num * @max_ports
  end

  def peer_port(num) do
    20001 + num * @max_ports
  end

  def rpc_port(num) do
    20002 + num * @max_ports
  end

  def rpcs_port(num) do
    20003 + num * @max_ports
  end

  def name_clone(n) do
    {:ok, name} = :inet.gethostname()
    String.to_atom("clone_#{n}@#{name}")
  end

  def start_clones(number) do
    kill_clones()
    basedir = File.cwd!() <> "/clones"
    File.rm_rf!(basedir)
    File.mkdir!(basedir)

    for num <- 1..number do
      clonedir = "#{basedir}/#{num}/"
      file = File.stream!("#{basedir}/#{num}.log")

      spawn_link(fn ->
        System.cmd(
          "iex",
          ["--cookie", @cookie, "-S", "mix", "run"],
          env: [
            {"MIX_ENV", "test"},
            {"DATA_DIR", clonedir},
            {"RPC_PORT", "#{rpc_port(num)}"},
            {"RPCS_PORT", "#{rpcs_port(num)}"},
            {"EDGE_PORT", "#{edge_port(num)}"},
            {"EDGE2_PORT", "#{edge2_port(num)}"},
            {"PEER_PORT", "#{peer_port(num)}"},
            {"SEED", "none"}
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
    wait_for(
      fn ->
        {ret, _} = System.cmd("pgrep", ["-fc", @cookie])
        {count, _} = Integer.parse(ret)
        count == target_count
      end,
      "clones",
      seconds
    )
  end

  def kill_clones() do
    System.cmd("pkill", ["-fc", "-9", @cookie])
    :ok = wait_clones(0, 60)
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
        Process.sleep(1000)
        wait_for(fun, comment, timeout - 1)
    end
  end
end
