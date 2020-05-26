# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
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
        %{stage: 0, ticks: 0, min_conns: 2, min_ticks: 4}
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
        if ticks >= min_ticks do
          if Process.whereis(:active_sync) != nil do
            %{state | ticks: 0}
          else
            Diode.start_client_network()
            %{state | stage: 1}
          end
        else
          %{state | ticks: ticks + 1}
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
