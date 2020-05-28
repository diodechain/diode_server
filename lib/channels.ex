defmodule Channels do
  # Automatically defines child_spec/1
  use Supervisor

  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_args) do
    Supervisor.init([], strategy: :one_for_one)
  end

  def ensure(ch) do
    Supervisor.start_child(__MODULE__, %{
      id: Object.Channel.key(ch),
      start: {Network.Channel, :start_link, [ch]}
    })
    |> case do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
