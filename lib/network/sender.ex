defmodule Network.Sender do
  @doc """
    Quality-Of-Service aware network sender. The idea is to wrap
    around a real socket and send on multiple "partitions". Small partitions
    with fewer data in the queue are always preferred over the large partitions
  """
  use GenServer
  alias Network.Sender
  defstruct [:partitions, :waiting]

  def new(socket) do
    {:ok, pid} = GenServer.start_link(__MODULE__, [socket], hibernate_after: 5_000)
    pid
  end

  def stop(q) do
    GenServer.stop(q, :normal)
  end

  def push_async(q, partition, data) do
    GenServer.call(q, {:push_async, partition, data})
  end

  def push(q, partition, data) do
    GenServer.call(q, {:push, partition, data}, :infinity)
  end

  def pop(q) do
    GenServer.call(q, :pop)
  end

  def await(q) do
    GenServer.call(q, :await, :infinity)
  end

  @impl true
  def handle_call(
        {:push_async, partition, data},
        _from,
        state = %Sender{partitions: partitions, waiting: nil}
      ) do
    ps =
      Map.update(partitions, partition, {[data], [nil]}, fn {q, rest} ->
        {q ++ [data], rest ++ [nil]}
      end)

    {:reply, :ok, %Sender{state | partitions: ps}}
  end

  @impl true
  def handle_call(
        {:push_async, _partition, data},
        _from,
        state = %Sender{waiting: from}
      ) do
    GenServer.reply(from, data)
    {:reply, :ok, %Sender{state | waiting: nil}}
  end

  @impl true
  def handle_call(
        {:push, partition, data},
        from,
        state = %Sender{partitions: partitions, waiting: nil}
      ) do
    ps =
      Map.update(partitions, partition, {[data], [from]}, fn {q, rest} ->
        {q ++ [data], rest ++ [from]}
      end)

    {:noreply, %Sender{state | partitions: ps}}
  end

  @impl true
  def handle_call(
        {:push, _partition, data},
        _from,
        state = %Sender{waiting: from}
      ) do
    GenServer.reply(from, data)
    {:reply, :ok, %Sender{state | waiting: nil}}
  end

  @impl true
  def handle_call(:pop, _from, state = %Sender{partitions: partitions}) do
    min =
      Enum.min(
        partitions,
        fn {_ka, {data_a, _from_a}}, {_kb, {data_b, _from_b}} ->
          :erts_debug.flat_size(data_a) < :erts_debug.flat_size(data_b)
        end,
        fn -> nil end
      )

    case min do
      nil ->
        {:reply, nil, state}

      {partition, {[data | q], [from | rest]}} ->
        ps =
          if q == [] do
            Map.delete(partitions, partition)
          else
            Map.put(partitions, partition, {q, rest})
          end

        state = %Sender{state | partitions: ps}
        if from != nil, do: GenServer.reply(from, :ok)
        {:reply, data, state}
    end
  end

  @impl true
  def handle_call(:await, from, state) do
    do_await(from, state)
  end

  # Coalescing data frames into 64kb at least when available
  defp do_await(data \\ "", from, state = %Sender{partitions: partitions, waiting: nil}) do
    if map_size(partitions) > 0 and byte_size(data) < 64_000 do
      {:reply, new_data, state} = handle_call(:pop, from, state)
      do_await(data <> new_data, from, state)
    else
      if byte_size(data) > 0 do
        {:reply, data, state}
      else
        {:noreply, %Sender{state | waiting: from}}
      end
    end
  end

  @impl true
  def init([socket]) do
    q = self()

    spawn_link(fn ->
      relayer_loop(q, socket)
    end)

    {:ok, %Sender{partitions: %{}, waiting: nil}}
  end

  defp relayer_loop(q, socket) do
    case :ssl.send(socket, await(q)) do
      :ok -> relayer_loop(q, socket)
      other -> Process.exit(self(), other)
    end
  end
end
