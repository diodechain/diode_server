defmodule NodeAgent do
  @moduledoc """
  Response for starting and running a traffic relay that connects
  to this blockchain node.
  """
  use GenServer
  defstruct port: nil, out: "", log: nil

  def cmd() do
    System.get_env("DIODE_NODE_CMD", "/opt/diode_node/bin/diode_node")
  end

  def available?() do
    File.exists?(cmd())
  end

  def start_link() do
    GenServer.start_link(__MODULE__, %NodeAgent{}, name: __MODULE__)
  end

  def init(state) do
    log = File.open!("traffic_node.log", [:write, :binary])

    if available?() do
      GenServer.cast(self(), :restart)
    end

    {:ok, %NodeAgent{state | log: log}}
  end

  def handle_cast(:restart, state) do
    {:noreply, do_restart(state)}
  end

  defp do_restart(state = %{port: port}) do
    if port != nil do
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    unset =
      [
        "_",
        "BINDIR",
        "ELIXIR_ERL_OPTIONS",
        "ERL_CRASH_DUMP_BYTES",
        # "ERL_EPMD_ADDRESS",
        "EMU",
        "MIX_ARCHIVES",
        "MIX_ENV",
        "MIX_HOME",
        "PROGNAME",
        "RELEASE_BOOT_SCRIPT_CLEAN",
        "RELEASE_BOOT_SCRIPT",
        "RELEASE_COMMAND",
        "RELEASE_COOKIE",
        "RELEASE_DISTRIBUTION",
        "RELEASE_MODE",
        "RELEASE_NAME",
        "RELEASE_NODE",
        "RELEASE_PROG",
        "RELEASE_REMOTE_VM_ARGS",
        "RELEASE_ROOT",
        "RELEASE_SYS_CONFIG",
        "RELEASE_TMP",
        "RELEASE_VSN",
        "ROOTDIR"
      ]
      |> Enum.map(fn k -> {k, ""} end)

    case System.cmd(cmd(), ["pid"], env: unset) do
      {_pid, 0} -> {"", 0} = System.cmd(cmd(), ["stop"], env: unset)
      {_error, 1} -> :ok
    end

    port =
      Port.open({:spawn_executable, cmd()}, [
        {:args, ["start"]},
        {:env,
         [
           {"PRIVATE", Base16.encode(Wallet.privkey!(Diode.wallet()))},
           {"DATA_DIR", Diode.data_dir("diode_node")},
           {"CHAINS_DIODE_WS", "http://localhost:#{Diode.rpc_port()}/ws"},
           {"CHAINS_DIODE_RPC", "http://localhost:#{Diode.rpc_port()}"},
           {"PARENT_CWD", File.cwd!()}
           | unset
         ]
         |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)},
        :stream,
        :exit_status,
        :hide,
        :use_stdio,
        :binary,
        :stderr_to_stdout
      ])

    %{state | port: port, out: ""}
  end

  def handle_info({port0, {:exit_status, status}}, state = %{log: log, port: port}) do
    if port0 == port do
      IO.puts(log, "Diode Node exited with status #{status}")
      {:noreply, do_restart(%{state | port: nil})}
    else
      {:noreply, state}
    end
  end

  def handle_info({port0, {:data, msg}}, state = %{log: log, out: out, port: port}) do
    if port0 == port do
      IO.puts(log, msg)
      IO.puts("DIODE_NODE: " <> String.trim_trailing(msg))
      {:noreply, %{state | out: out <> msg}}
    else
      {:noreply, state}
    end
  end
end
