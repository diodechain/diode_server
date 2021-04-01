# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule PubSubTest do
  use ExUnit.Case

  test "sub unsub" do
    assert PubSub.subscribers(:test) == []
    PubSub.subscribe(:test)
    assert PubSub.subscribers(:test) == [self()]
    PubSub.unsubscribe(:test)
    assert PubSub.subscribers(:test) == []
  end

  test "two processes" do
    outer = self()
    assert PubSub.subscribers(:test) == []

    inner =
      spawn(fn ->
        PubSub.subscribe(:test)
        send(outer, :subscribed)

        receive do
          :kick -> send(outer, :done)
        end
      end)

    receive do
      :subscribed -> assert PubSub.subscribers(:test) == [inner]
    end

    PubSub.publish(:test, :kick)

    receive do
      :done -> :ok
    end

    # Allowing 100ms for demonitor to happen
    Process.sleep(100)
    assert PubSub.subscribers(:test) == []
  end
end
