# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule ProcessLruTest do
  use ExUnit.Case

  test "base" do
    lru = ProcessLru.new(10)
    assert ProcessLru.size(lru) == 0

    ProcessLru.put(lru, "key", "value")
    assert ProcessLru.size(lru) == 1

    assert ProcessLru.get(lru, "key") == "value"

    # ProcessLru should not cache nil return values
    assert ProcessLru.fetch(lru, "nothing", fn -> nil end) == nil
    assert ProcessLru.fetch(lru, "nothing", fn -> "yay" end) == "yay"
    assert ProcessLru.get(lru, "nothing") == "yay"
  end

  test "limit" do
    lru = ProcessLru.new(3)
    assert ProcessLru.size(lru) == 0

    ProcessLru.put(lru, "a", "avalue")
    ProcessLru.put(lru, "b", "bvalue")
    ProcessLru.put(lru, "c", "cvalue")

    assert ProcessLru.size(lru) == 3
    assert ProcessLru.get(lru, "a") == "avalue"
    assert ProcessLru.get(lru, "b") == "bvalue"
    assert ProcessLru.get(lru, "c") == "cvalue"

    ProcessLru.put(lru, "d", "dvalue")

    assert ProcessLru.size(lru) == 3
    assert ProcessLru.get(lru, "a") == nil
    assert ProcessLru.get(lru, "b") == "bvalue"
    assert ProcessLru.get(lru, "c") == "cvalue"
    assert ProcessLru.get(lru, "d") == "dvalue"
  end

  test "repeat" do
    lru = ProcessLru.new(3)
    assert ProcessLru.size(lru) == 0

    ProcessLru.put(lru, "a", "avalue")
    ProcessLru.put(lru, "b", "bvalue")
    ProcessLru.put(lru, "c", "cvalue")

    assert ProcessLru.size(lru) == 3
    assert ProcessLru.get(lru, "a") == "avalue"
    assert ProcessLru.get(lru, "b") == "bvalue"
    assert ProcessLru.get(lru, "c") == "cvalue"

    ProcessLru.put(lru, "a", "avalue2")

    assert ProcessLru.size(lru) == 3
    assert ProcessLru.get(lru, "a") == "avalue2"
    assert ProcessLru.get(lru, "b") == "bvalue"
    assert ProcessLru.get(lru, "c") == "cvalue"
  end
end
