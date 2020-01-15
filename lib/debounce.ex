# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Debounce do
  use GenServer

  @spec start_link(any) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_arg) do
    {:ok, _} = :timer.send_interval(100, :tick)
    __MODULE__ = :ets.new(__MODULE__, [{:keypos, 1}, :ordered_set, :named_table])
    {:ok, %{}}
  end

  @spec delay(term(), (() -> any()), non_neg_integer()) :: :ok
  def delay(key, fun, timeout \\ 5000) do
    GenServer.cast(__MODULE__, {:delay, key, fun, timeout})
  end

  @spec apply(term(), (() -> any()), non_neg_integer()) :: :ok
  def apply(key, fun, timeout \\ 5000) do
    GenServer.cast(__MODULE__, {:apply, key, fun, timeout})
  end

  def handle_cast({:delay, key, fun, timeout}, state) do
    calltime = time() + timeout

    case :ets.lookup(__MODULE__, calltime) do
      [] -> :ets.insert(__MODULE__, {calltime, [key]})
      [{_, keys}] -> :ets.insert(__MODULE__, {calltime, [key | keys]})
    end

    {:noreply, Map.put(state, key, {calltime, fun})}
  end

  def handle_cast({:apply, key, fun, timeout}, state) do
    case Map.get(state, key) do
      nil -> handle_cast({:delay, key, fun, timeout}, state)
      {calltime, _fun} -> {:noreply, Map.put(state, key, {calltime, fun})}
    end
  end

  def handle_info(:tick, state) do
    {:noreply, update(state, time())}
  end

  defp update(state, now) do
    case :ets.first(__MODULE__) do
      :"$end_of_table" ->
        state

      ts when ts > now ->
        state

      ts ->
        state =
          hd(:ets.lookup(__MODULE__, ts))
          |> elem(1)
          |> Enum.reduce(state, fn key, state ->
            case Map.get(state, key) do
              {^ts, fun} ->
                spawn(fun)
                Map.delete(state, key)

              _ ->
                state
            end
          end)

        :ets.delete(__MODULE__, ts)
        update(state, now)
    end
  end

  defp time() do
    System.monotonic_time(:millisecond)
  end
end
