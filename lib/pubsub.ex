defmodule PubSub do
  def subscribe(topic) do
    :pg2.create(topic)
    :pg2.join(topic, self())
  end

  def unsubscribe(topic) do
    :pg2.leave(topic, self())
  end

  def subscribers(topic) do
    case :pg2.get_local_members(topic) do
      {:error, _} -> []
      pids -> pids
    end
  end

  def publish(topic, msg) do
    subs = subscribers(topic)

    for pid <- subs do
      send(pid, msg)
    end

    subs
  end
end
