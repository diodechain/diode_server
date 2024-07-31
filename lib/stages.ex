# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Stages do
  use GenServer
  defstruct stage: 0, ticks: 0, min_conns: 2, min_ticks: 20, probable_peak: 0

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_arg) do
    :timer.send_interval(1_000, :tick)

    state =
      if Diode.dev_mode?() do
        %Stages{min_conns: 0, min_ticks: 0}
      else
        %Stages{}
      end

    {:ok, state}
  end

  def stage() do
    GenServer.call(__MODULE__, :stage)
  end

  def probable_peak(peak) do
    GenServer.cast(__MODULE__, {:probable_peak, peak})
  end

  def handle_cast({:probable_peak, peak}, state) do
    {:noreply, %{state | probable_peak: max(state.probable_peak, peak - 100)}}
  end

  def handle_call(:stage, _from, state = %{stage: stage}) do
    {:reply, stage, state}
  end

  def handle_info(
        :tick,
        state = %{
          stage: 0,
          ticks: ticks,
          min_conns: min_conns,
          min_ticks: min_ticks,
          probable_peak: peak
        }
      ) do
    conns = Network.Server.get_connections(Network.PeerHandler)

    ticks =
      cond do
        map_size(conns) < min_conns -> 0
        Diode.syncing?() -> 0
        peak > Chain.peak() -> 0
        true -> ticks + 1
      end

    state = %{state | ticks: ticks}

    state =
      if ticks >= min_ticks do
        Diode.start_client_network()
        %{state | stage: 1}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:tick, state = %{stage: 1}) do
    {:noreply, state}
  end
end
