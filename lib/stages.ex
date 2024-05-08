# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Stages do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_arg) do
    :timer.send_interval(1_000, :tick)

    state =
      if Diode.dev_mode?() do
        %{stage: 0, ticks: 0, min_conns: 0, min_ticks: 0}
      else
        %{stage: 0, ticks: 0, min_conns: 2, min_ticks: 30}
      end

    {:ok, state}
  end

  def stage() do
    GenServer.call(__MODULE__, :stage)
  end

  def handle_call(:stage, _from, state = %{stage: stage}) do
    {:reply, stage, state}
  end

  def handle_info(
        :tick,
        state = %{stage: 0, ticks: ticks, min_conns: min_conns, min_ticks: min_ticks}
      ) do
    conns = Network.Server.get_connections(Network.PeerHandler)

    state =
      if map_size(conns) >= min_conns do
        if Diode.syncing?() do
          %{state | ticks: 0}
        else
          if ticks >= min_ticks do
            Diode.start_client_network()
            %{state | stage: 1}
          else
            %{state | ticks: ticks + 1}
          end
        end
      else
        %{state | ticks: 0}
      end

    {:noreply, state}
  end

  def handle_info(:tick, state = %{stage: 1}) do
    {:noreply, state}
  end
end
