defmodule Model.Stats do
  use GenServer

  def init(_args) do
    :timer.send_interval(1000, :tick)

    {:ok,
     %{
       show: false,
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

  def tc(metric, fun) do
    {time, ret} = :timer.tc(fun)
    incr(metric, time)
    ret
  end

  def toggle_print() do
    cast(fn state ->
      %{state | show: !state.show}
    end)
  end

  defp cast(fun) do
    GenServer.cast(__MODULE__, {:cast, fun})
  end

  def handle_cast({:cast, fun}, state) do
    {:noreply, fun.(state)}
  end

  def handle_info(:tick, state) do
    if state.show, do: :io.format("Stats: ~p~n", [state.done_counters])
    {:noreply, %{state | done_counters: state.counters, counters: %{}}}
  end
end
