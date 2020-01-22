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

  @spec immediate(term(), (() -> any()), non_neg_integer()) :: :ok
  @doc """
    immediate executes the function immediately but blocks any further call
      under the same key for the given timeout.
  """
  def immediate(key, fun, timeout \\ 5000) do
    GenServer.cast(__MODULE__, {:immediate, key, fun, timeout})
  end

  @spec delay(term(), (() -> any()), non_neg_integer()) :: :ok
  @doc """
    delay executes the function after the specified timeout t0 + timeout,
      when delay is called multipe times the timeout is reset based on the
      most recent call (t1 + timeout, t2 + timeout) etc... the fun is also updated
  """
  def delay(key, fun, timeout \\ 5000) do
    GenServer.cast(__MODULE__, {:delay, key, fun, timeout})
  end

  @spec apply(term(), (() -> any()), non_neg_integer()) :: :ok
  @doc """
    apply executes the function after the specified timeout t0 + timeout,
      when apply is called multiple times it does not affect the point
      in time when the next call is happening (t0 + timeout) but updates the fun
  """
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

  def handle_cast({:immediate, key, fun, timeout}, state) do
    calltime = time() + timeout

    case :ets.lookup(__MODULE__, calltime) do
      [] ->
        execute(fun)
        :ets.insert(__MODULE__, {calltime, [key]})
        {:noreply, Map.put(state, key, {calltime, nil})}

      [{_, keys}] ->
        :ets.insert(__MODULE__, {calltime, [key | keys]})
        {:noreply, Map.put(state, key, {calltime, fun})}
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
                execute(fun)
                Map.delete(state, key)

              _ ->
                state
            end
          end)

        :ets.delete(__MODULE__, ts)
        update(state, now)
    end
  end

  defp execute(nil) do
    :ok
  end

  defp execute(fun) do
    spawn(fun)
  end

  defp time() do
    System.monotonic_time(:millisecond)
  end
end
