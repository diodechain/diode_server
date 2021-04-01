# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule PubSub do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_arg) do
    __MODULE__ = :ets.new(__MODULE__, [:named_table, :public, :duplicate_bag])
    {:ok, %{}}
  end

  def handle_cast({:monitor, pid}, state) do
    state =
      case Map.has_key?(state, pid) do
        false -> Map.put(state, pid, :erlang.monitor(:process, pid))
        true -> state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    :ets.match_delete(__MODULE__, {:_, pid})
    {^ref, state} = Map.pop(state, pid)
    :erlang.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def subscribe(topic) do
    GenServer.cast(__MODULE__, {:monitor, self()})
    :ets.insert(__MODULE__, {topic, self()})
  end

  def unsubscribe(topic) do
    :ets.match_delete(__MODULE__, {topic, self()})
  end

  def subscribers(topic) do
    :ets.match(__MODULE__, {topic, :"$1"})
    |> List.flatten()
  end

  def publish(topic, msg) do
    subs = subscribers(topic)
    for pid <- subs, do: send(pid, msg)
    subs
  end
end
