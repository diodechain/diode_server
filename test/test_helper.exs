# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
import While

ExUnit.start(seed: 0)

while Stages.stage() < 1 do
  IO.puts("Waiting for RPC")
  Process.sleep(1_000)
end

defmodule TestHelper do
  @delay_clone 10_000
  @cookie "EXTMP_K66"
  @max_ports 10

  def reset() do
    kill_clones()
    Chain.Pool.flush()
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
      add_clone(num)
    end

    :ok = wait_clones(number, 60)
    Process.sleep(@delay_clone)
  end

  def add_clone(num) do
    basedir = File.cwd!() <> "/clones"
    clonedir = "#{basedir}/#{num}/"
    file = File.open!("#{basedir}/#{num}.log", [:write, :binary])

    spawn_link(fn ->
      iex = System.find_executable("iex")
      args = ["--cookie", @cookie, "-S", "mix", "run"]

      env =
        [
          {"MIX_ENV", "test"},
          {"DATA_DIR", clonedir},
          {"RPC_PORT", "#{rpc_port(num)}"},
          {"RPCS_PORT", "#{rpcs_port(num)}"},
          {"EDGE2_PORT", "#{edge2_port(num)}"},
          {"PEER_PORT", "#{peer_port(num)}"},
          {"SEED", "none"}
        ]
        |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

      port =
        Port.open({:spawn_executable, iex}, [
          {:args, args},
          {:env, env},
          :stream,
          :exit_status,
          :hide,
          :use_stdio,
          :stderr_to_stdout
        ])

      # :io.format("port clone_#{num}: ~p~n", [port])
      true = Process.register(port, String.to_atom("clone_#{num}"))

      clone_loop(port, file)
    end)

    Process.sleep(1000)
  end

  defp clone_loop(port, file) do
    receive do
      {^port, {:data, msg}} ->
        IO.write(file, msg)

      msg ->
        :io.format("RECEIVED: ~p~n", [msg])
    end

    clone_loop(port, file)
  end

  def freeze_clone(num) do
    port = Process.whereis(String.to_atom("clone_#{num}"))
    # :io.format("port info: ~p ~p~n", [port, Port.info(port)])
    {:os_pid, pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-SIGSTOP", "#{pid}"])
  end

  def unfreeze_clone(num) do
    port = Process.whereis(String.to_atom("clone_#{num}"))
    {:os_pid, pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-SIGCONT", "#{pid}"])
  end

  def wait_clones(_target_count, 0) do
    :error
  end

  def wait_clones(target_count, seconds) do
    wait_for(
      fn -> count_clones() == target_count end,
      "clones #{count_clones()}/#{target_count}",
      seconds
    )
  end

  def is_macos() do
    :os.type() == {:unix, :darwin}
  end

  def count_clones() do
    if is_macos() do
      {ret, _} = System.cmd("pgrep", ["-f", @cookie])
      String.split(ret, "\n", trim: true) |> Enum.count()
    else
      {ret, _} = System.cmd("pgrep", ["-fc", @cookie])
      {count, _} = Integer.parse(ret)
      count
    end
  end

  def kill_clones() do
    System.cmd("pkill", ["-9", "-f", @cookie])
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
