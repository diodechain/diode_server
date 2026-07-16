# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule MemoryGuard do
  @moduledoc """
  Early-stop watchdog for runaway process RSS growth.

  Polls `/proc/self/status` and halts the VM when either:
  - absolute RSS exceeds `MEMORY_LIMIT_MB` (default: 80% of MemTotal), or
  - RSS grows faster than `MEMORY_GROWTH_MB` over `MEMORY_GROWTH_WINDOW_SEC`
    (defaults: 2048 MB in 15 seconds).

  Disable with `MEMORY_GUARD=0`.
  """
  use GenServer
  require Logger

  @default_interval_ms 1_000
  @default_growth_mb 2_048
  @default_growth_window_sec 15
  @default_limit_ratio 0.80

  defstruct baseline_rss_kb: 0,
            samples: [],
            limit_kb: nil,
            growth_kb: nil,
            growth_window_ms: nil,
            interval_ms: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    if disabled?() do
      Logger.info("MemoryGuard: disabled (MEMORY_GUARD=0)")
      :ignore
    else
      interval_ms =
        Keyword.get(opts, :interval_ms, env_int("MEMORY_GUARD_INTERVAL_MS", @default_interval_ms))

      growth_kb =
        Keyword.get(opts, :growth_kb, env_int("MEMORY_GROWTH_MB", @default_growth_mb) * 1024)

      growth_window_ms =
        Keyword.get(
          opts,
          :growth_window_ms,
          env_int("MEMORY_GROWTH_WINDOW_SEC", @default_growth_window_sec) * 1_000
        )

      limit_kb =
        Keyword.get(opts, :limit_kb, resolve_limit_kb())

      rss = read_rss_kb()

      Logger.info(
        "MemoryGuard: watching RSS limit=#{div(limit_kb, 1024)}MB " <>
          "growth=#{div(growth_kb, 1024)}MB/#{div(growth_window_ms, 1000)}s " <>
          "interval=#{interval_ms}ms baseline=#{div(rss, 1024)}MB"
      )

      :timer.send_interval(interval_ms, :tick)

      {:ok,
       %__MODULE__{
         baseline_rss_kb: rss,
         samples: [{monotonic_ms(), rss}],
         limit_kb: limit_kb,
         growth_kb: growth_kb,
         growth_window_ms: growth_window_ms,
         interval_ms: interval_ms
       }}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    rss = read_rss_kb()
    now = monotonic_ms()
    samples = trim_samples([{now, rss} | state.samples], now, state.growth_window_ms)

    cond do
      rss >= state.limit_kb ->
        halt!("absolute RSS limit", state, rss, samples)

      rapid_growth?(samples, state.growth_kb) ->
        halt!("rapid RSS growth", state, rss, samples)

      true ->
        {:noreply, %{state | samples: samples}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp halt!(reason, state, rss, samples) do
    {oldest_ms, oldest_rss} = List.last(samples)
    newest_ms = elem(hd(samples), 0)
    window_s = max(div(newest_ms - oldest_ms, 1000), 1)
    delta_mb = div(rss - oldest_rss, 1024)
    beam_total = :erlang.memory(:total)

    nif =
      try do
        CMerkleTree.nif_stats()
      rescue
        _ -> :unavailable
      catch
        _, _ -> :unavailable
      end

    Logger.error("""
    MemoryGuard: halting — #{reason}
      rss=#{div(rss, 1024)}MB limit=#{div(state.limit_kb, 1024)}MB \
    baseline=#{div(state.baseline_rss_kb, 1024)}MB
      growth=#{delta_mb}MB over #{window_s}s (threshold=#{div(state.growth_kb, 1024)}MB)
      erlang.memory(total)=#{div(beam_total, 1024 * 1024)}MB
      nif_stats=#{inspect(nif)}
      meminfo=#{inspect(meminfo_summary())}
    """)

    # Hard halt — System.stop can hang while supervisors are stuck in init.
    :erlang.halt(1)
  end

  defp rapid_growth?(samples, _growth_kb) when length(samples) < 2, do: false

  defp rapid_growth?(samples, growth_kb) do
    {oldest_ms, oldest_rss} = List.last(samples)
    {newest_ms, newest_rss} = hd(samples)
    newest_rss - oldest_rss >= growth_kb and newest_ms > oldest_ms
  end

  defp trim_samples(samples, now, window_ms) do
    cutoff = now - window_ms
    # Keep at least two samples so growth can be measured once the window fills.
    kept = Enum.take_while(samples, fn {t, _} -> t >= cutoff end)

    case kept do
      [] -> Enum.take(samples, 2)
      [_] = one -> one ++ Enum.take(Enum.drop(samples, 1), 1)
      many -> many
    end
  end

  defp resolve_limit_kb do
    case System.get_env("MEMORY_LIMIT_MB") do
      nil ->
        case mem_total_kb() do
          nil -> 24 * 1024 * 1024
          total -> trunc(total * @default_limit_ratio)
        end

      mb ->
        String.to_integer(mb) * 1024
    end
  end

  defp disabled? do
    System.get_env("MEMORY_GUARD") in ["0", "false", "off"]
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  def read_rss_kb do
    case File.read("/proc/self/status") do
      {:ok, body} ->
        case Regex.run(~r/^VmRSS:\s+(\d+)\s+kB/m, body) do
          [_, n] -> String.to_integer(n)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp mem_total_kb do
    case File.read("/proc/meminfo") do
      {:ok, body} ->
        case Regex.run(~r/^MemTotal:\s+(\d+)\s+kB/m, body) do
          [_, n] -> String.to_integer(n)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp meminfo_summary do
    case File.read("/proc/meminfo") do
      {:ok, body} ->
        for key <- ["MemTotal", "MemAvailable", "MemFree", "SwapTotal", "SwapFree"], into: %{} do
          case Regex.run(~r/^#{key}:\s+(\d+)\s+kB/m, body) do
            [_, n] -> {key, String.to_integer(n)}
            _ -> {key, nil}
          end
        end

      _ ->
        %{}
    end
  end
end
