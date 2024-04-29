# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Stats do
  use GenServer
  @key {__MODULE__, :show}
  def init(_args) do
    :timer.send_interval(1000, :tick)
    :persistent_term.put(@key, 0)

    {:ok,
     %{
       counters: %{},
       done_counters: %{}
     }}
  end

  def start_link() do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__, hibernate_after: 5_000)
  end

  def incr(metric, value \\ 1) do
    cast(fn state ->
      counters = Map.update(state.counters, metric, value, fn i -> i + value end)
      %{state | counters: counters}
    end)
  end

  def get(metric, default \\ 0) do
    GenServer.call(__MODULE__, :get)
    |> Map.get(metric, default)
  end

  def tc(metric, fun) do
    {_time, ret} = tc!(metric, fun)
    ret
  end

  def tc!(metric, fun) do
    if :persistent_term.get(@key, nil) do
      parent = Process.get(__MODULE__, "")
      name = "#{parent}/#{metric}"
      Process.put(__MODULE__, name)
      {time, ret} = :timer.tc(fun)
      incr("#{name}_time", time)
      incr("#{name}_cnt")
      Process.put(__MODULE__, parent)
      {time, ret}
    else
      {0, fun.()}
    end
  end

  def toggle_print(intervall \\ 1) when is_integer(intervall) do
    cast(fn state ->
      if :persistent_term.get(@key) <= 0 do
        :persistent_term.put(@key, intervall)
      else
        :persistent_term.put(@key, 0)
      end

      state
    end)
  end

  defp cast(fun) do
    GenServer.cast(__MODULE__, {:cast, fun})
  end

  def handle_cast({:cast, fun}, state) do
    {:noreply, fun.(state)}
  end

  def handle_call(:get, _from, state) do
    {:reply, state.done_counters, state}
  end

  def handle_info(:tick, state) do
    if :persistent_term.get(@key) > 0 do
      case Process.get(:batch, :persistent_term.get(@key)) do
        0 ->
          :io.format(" Stats~n")

          :io.format(
            "======================================================== MICROS ======= COUNT ===~n"
          )

          done_counters =
            Enum.map(state.done_counters, fn {key, value} -> {"#{key}", value} end)
            |> Map.new()

          keys =
            done_counters
            |> Enum.filter(fn {key, _value} -> String.ends_with?(key, "_cnt") end)
            |> Enum.map(fn {key, _value} ->
              key = String.replace_suffix(key, "_cnt", "")
              cnt = Map.get(done_counters, "#{key}_cnt", 0)
              time = Map.get(done_counters, "#{key}_time", 0)
              {key, cnt, time}
            end)
            |> Enum.sort(fn {_, _, a}, {_, _, b} -> a > b end)

          for {key, cnt, time} <- keys do
            len = byte_size(key)

            key =
              if len > 48 do
                "..." <> binary_part(key, len - 45, 45)
              else
                String.pad_trailing(key, 48)
              end

            :io.format("| ~s: ~14B | ~10B |~n", [key, time, cnt])
          end

          :io.format(
            "=================================================================================~n~n"
          )

          Process.put(:batch, :persistent_term.get(@key))
          {:noreply, %{state | done_counters: state.counters, counters: %{}}}

        x ->
          Process.put(:batch, x - 1)
          {:noreply, state}
      end
    else
      {:noreply, %{state | done_counters: state.counters, counters: %{}}}
    end
  end
end
