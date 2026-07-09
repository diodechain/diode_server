# CMerkleTree NIF — memory leak watchdog for cmerkle_leak_test.exs.
#
# Run from repo root:
#   mix run --no-start scripts/cmerkle_leak_watchdog.exs -- \
#     mix run --no-start scripts/cmerkle_leak_test.exs -- --rounds 50
#
# Options (before `--`):
#   --progress-timeout SEC   no LEAK_OK for this long (default: 120)
#   --wall-timeout SEC       max total runtime (default: 0 = unlimited)
#   --poll-interval SEC      poll interval (default: 5)

defmodule CMerkleLeakWatchdog do
  @moduledoc false

  @progress_re ~r/(?:^|\s)LEAK_OK\b/

  def main(argv) do
    argv = normalize_argv(argv)
    {opts, cmd} = parse_watchdog_argv(argv)

    if cmd == [] do
      IO.puts(
        :stderr,
        "usage: mix run --no-start scripts/cmerkle_leak_watchdog.exs -- [opts] -- <command...>"
      )

      System.halt(2)
    end

    progress_timeout_ms = Keyword.get(opts, :progress_timeout, 120) * 1_000
    wall_timeout_ms = Keyword.get(opts, :wall_timeout, 0) * 1_000
    poll_ms = Keyword.get(opts, :poll_interval, 5) * 1_000

    IO.puts(:stderr, """
    === CMerkleTree leak watchdog ===
    command=#{inspect(cmd)}
    progress_timeout=#{div(progress_timeout_ms, 1000)}s wall_timeout=#{format_wall(wall_timeout_ms)}
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
      last_progress_ms: System.monotonic_time(:millisecond),
      start_ms: System.monotonic_time(:millisecond)
    })
  end

  defp monitor_loop(port, ctx) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        IO.write(line <> "\n")

        ctx =
          if Regex.match?(@progress_re, line) do
            %{ctx | last_progress_ms: System.monotonic_time(:millisecond)}
          else
            ctx
          end

        check_timeouts(port, ctx)

      {^port, {:data, data}} when is_binary(data) ->
        IO.write(data)
        check_timeouts(port, ctx)

      {^port, {:exit_status, status}} ->
        System.halt(status)
    after
      ctx.poll_ms ->
        check_timeouts(port, ctx)
    end
  end

  defp check_timeouts(port, ctx) do
    now = System.monotonic_time(:millisecond)

    if ctx.wall_timeout_ms > 0 and now - ctx.start_ms > ctx.wall_timeout_ms do
      Port.close(port)
      IO.puts(:stderr, "LEAK_WATCHDOG wall timeout")
      System.halt(124)
    end

    if now - ctx.last_progress_ms > ctx.progress_timeout_ms do
      Port.close(port)
      IO.puts(:stderr, "LEAK_WATCHDOG progress timeout")
      System.halt(124)
    end

    monitor_loop(port, ctx)
  end

  defp format_wall(0), do: "unlimited"
  defp format_wall(ms), do: "#{div(ms, 1000)}s"

  defp normalize_argv(argv) do
    case argv do
      ["--" | rest] -> rest
      other -> other
    end
  end

  defp parse_watchdog_argv(argv) do
    {opts, rest} =
      OptionParser.parse!(argv,
        strict: [
          progress_timeout: :integer,
          wall_timeout: :integer,
          poll_interval: :integer
        ]
      )

    case Enum.split_while(rest, &(&1 != "--")) do
      {pre, ["--" | cmd]} -> {opts, cmd}
      {pre, []} -> {opts, pre}
      {pre, cmd} -> {opts, pre ++ cmd}
    end
  end

  defp resolve_command([cmd | args]) do
    case :os.type() do
      {:unix, :darwin} -> {String.to_charlist(cmd), Enum.map(args, &String.to_charlist/1)}
      _ -> {cmd, args}
    end
  end
end

CMerkleLeakWatchdog.main(System.argv())
