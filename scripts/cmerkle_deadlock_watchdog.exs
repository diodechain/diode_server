# CAccountMap NIF — deadlock / hang watchdog for fuzz and stress harnesses.
#
# Wraps a child command, monitors stdout/stderr for progress markers, and exits
# with code 124 if the child stops making progress or exceeds wall-clock budget.
#
# Run from repo root:
#   mix run --no-start scripts/cmerkle_deadlock_watchdog.exs -- \
#     mix run --no-start scripts/cmerkle_fuzz.exs -- --iterations 500 --seed 1
#
# Options (before `--`):
#   --progress-timeout SEC   no FUZZ_OK / PARALLEL_OK / WAVE_OK for this long (default: 60)
#   --wall-timeout SEC       max total runtime (default: 0 = unlimited)
#   --poll-interval SEC      poll interval (default: 5)
#
# Exit codes:
#   0   child exited 0
#   N   child exited N (N != 0)
#   124 progress or wall timeout (standard timeout convention)

defmodule CMerkleDeadlockWatchdog do
  @moduledoc false

  @progress_re ~r/(?:^|\s)(?:FUZZ_OK|PARALLEL_OK|WAVE_OK)\b/

  def main(argv) do
    argv = normalize_argv(argv)
    {opts, cmd} = parse_watchdog_argv(argv)

    if cmd == [] do
      IO.puts(
        :stderr,
        "usage: mix run --no-start scripts/cmerkle_deadlock_watchdog.exs -- [opts] -- <command...>"
      )

      System.halt(2)
    end

    progress_timeout_ms = Keyword.get(opts, :progress_timeout, 60) * 1_000
    wall_timeout_ms = Keyword.get(opts, :wall_timeout, 0) * 1_000
    poll_ms = Keyword.get(opts, :poll_interval, 5) * 1_000

    IO.puts(:stderr, """
    === CAccountMap deadlock watchdog ===
    command=#{inspect(cmd)}
    progress_timeout=#{div(progress_timeout_ms, 1000)}s wall_timeout=#{format_wall(wall_timeout_ms)} poll=#{div(poll_ms, 1000)}s
    """)

    {executable, args} = resolve_command(cmd)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:line, 65_536}
      ])

    monitor_loop(port, %{
      progress_timeout_ms: progress_timeout_ms,
      wall_timeout_ms: wall_timeout_ms,
      poll_ms: poll_ms,
      started_ms: System.monotonic_time(:millisecond),
      last_progress_ms: System.monotonic_time(:millisecond),
      buffer: ""
    })
  end

  defp format_wall(0), do: "unlimited"
  defp format_wall(ms), do: "#{div(ms, 1000)}s"

  defp resolve_command([bin | args]) do
    exe = System.find_executable(bin) || bin
    {exe, args}
  end

  defp normalize_argv(["--" | rest]), do: rest
  defp normalize_argv(other), do: other

  defp parse_watchdog_argv(argv) do
    parse_watchdog_argv(argv, [])
  end

  defp parse_watchdog_argv([], opts), do: {Enum.reverse(opts), []}

  defp parse_watchdog_argv(["--progress-timeout", val | rest], opts) do
    parse_watchdog_argv(rest, [{:progress_timeout, String.to_integer(val)} | opts])
  end

  defp parse_watchdog_argv(["--wall-timeout", val | rest], opts) do
    parse_watchdog_argv(rest, [{:wall_timeout, String.to_integer(val)} | opts])
  end

  defp parse_watchdog_argv(["--poll-interval", val | rest], opts) do
    parse_watchdog_argv(rest, [{:poll_interval, String.to_integer(val)} | opts])
  end

  defp parse_watchdog_argv(rest, opts), do: {Enum.reverse(opts), rest}

  defp monitor_loop(port, state) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        IO.puts(line)
        now = System.monotonic_time(:millisecond)
        last = if Regex.match?(@progress_re, line), do: now, else: state.last_progress_ms
        monitor_loop(port, %{state | last_progress_ms: last, buffer: ""})

      {^port, {:data, data}} when is_binary(data) ->
        buffer = state.buffer <> data
        {lines, rest} = take_complete_lines(buffer)

        last =
          Enum.reduce(lines, state.last_progress_ms, fn line, acc ->
            IO.puts(line)

            if Regex.match?(@progress_re, line),
              do: System.monotonic_time(:millisecond),
              else: acc
          end)

        monitor_loop(port, %{state | last_progress_ms: last, buffer: rest})

      {^port, {:exit_status, status}} ->
        if status == 0 do
          IO.puts(:stderr, "WATCHDOG_OK exit=#{status}")
          System.halt(0)
        else
          IO.puts(:stderr, "WATCHDOG_FAIL exit=#{status}")
          System.halt(status)
        end
    after
      state.poll_ms ->
        now = System.monotonic_time(:millisecond)

        cond do
          state.wall_timeout_ms > 0 and now - state.started_ms >= state.wall_timeout_ms ->
            IO.puts(:stderr, "WATCHDOG_TIMEOUT wall_clock")
            Port.close(port)
            System.halt(124)

          now - state.last_progress_ms >= state.progress_timeout_ms ->
            IO.puts(:stderr, "WATCHDOG_TIMEOUT no_progress")
            log_scheduler_snapshot()
            Port.close(port)
            System.halt(124)

          true ->
            monitor_loop(port, state)
        end
    end
  end

  defp take_complete_lines(buffer) do
    parts = String.split(buffer, "\n")

    case parts do
      [] ->
        {[], ""}

      [single] ->
        {[], single}

      lines ->
        {Enum.drop(lines, -1), List.last(lines)}
    end
  end

  defp log_scheduler_snapshot do
    total = :erlang.system_info(:schedulers)
    run_q = Diode.run_queue_total()
    mem = :erlang.memory(:total)

    IO.puts(
      :stderr,
      "WATCHDOG_SNAPSHOT schedulers=#{total} run_queue=#{run_q} memory_total=#{mem}"
    )
  rescue
    error ->
      IO.puts(:stderr, "WATCHDOG_SNAPSHOT failed=#{inspect(error)}")
  end
end

CMerkleDeadlockWatchdog.main(System.argv())
