# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Queue do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def shift() do
    GenServer.call(__MODULE__, :out)
  end

  def size() do
    GenServer.call(__MODULE__, :size)
  end

  def append(message) do
    GenServer.cast(__MODULE__, {:in, message})
  end

  ## Server Callbacks

  def init(:ok) do
    {:ok, :queue.new()}
  end

  def handle_call(:out, _from, queue) do
    {value, queue2} = :queue.out(queue)
    {:reply, value, queue2}
  end

  def handle_call(:size, _from, queue) do
    {:reply, :queue.len(queue), queue}
  end

  def handle_cast({:in, message}, queue) do
    {:noreply, :queue.in(message, queue)}
  end
end
