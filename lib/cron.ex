defmodule Cron do
  use GenServer
  require Logger

  defmodule Job do
    defstruct name: nil, interval: nil, fun: nil, startup: true
  end

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    jobs = [
      %Job{name: "Garbage Collect", interval: :timer.minutes(15), fun: &Diode.garbage_collect/0}
    ]

    for job <- jobs do
      :timer.send_interval(job.interval, self(), {:execute, job.name, job.fun})

      if job.startup do
        send(self(), {:execute, job.name, job.fun})
      end
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info({:execute, name, fun}, state) do
    Debouncer.immediate({__MODULE__, name}, fn ->
      Logger.info("Cron: Executing #{name}...")
      fun.()
    end)

    {:noreply, state}
  end
end
