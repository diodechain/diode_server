# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule LruTest do
  use ExUnit.Case

  test "base" do
    lru = Lru.new(10)
    assert Lru.size(lru) == 0

    lru = Lru.insert(lru, "key", "value")
    assert Lru.size(lru) == 1

    assert Lru.get(lru, "key") == "value"

    # Lru should not cache nil return values
    assert Lru.fetch(lru, "nothing", fn -> nil end) == {lru, nil}
    {lru, "yay"} = Lru.fetch(lru, "nothing", fn -> "yay" end)
    assert Lru.get(lru, "nothing") == "yay"
  end

  test "limit" do
    lru = Lru.new(3)
    assert Lru.size(lru) == 0

    lru = Lru.insert(lru, "a", "avalue")
    lru = Lru.insert(lru, "b", "bvalue")
    lru = Lru.insert(lru, "c", "cvalue")

    assert Lru.size(lru) == 3
    assert Lru.get(lru, "a") == "avalue"
    assert Lru.get(lru, "b") == "bvalue"
    assert Lru.get(lru, "c") == "cvalue"

    lru = Lru.insert(lru, "d", "dvalue")

    assert Lru.size(lru) == 3
    assert Lru.get(lru, "a") == nil
    assert Lru.get(lru, "b") == "bvalue"
    assert Lru.get(lru, "c") == "cvalue"
    assert Lru.get(lru, "d") == "dvalue"
  end

  test "repeat" do
    lru = Lru.new(3)
    assert Lru.size(lru) == 0

    lru = Lru.insert(lru, "a", "avalue")
    lru = Lru.insert(lru, "b", "bvalue")
    lru = Lru.insert(lru, "c", "cvalue")

    assert Lru.size(lru) == 3
    assert Lru.get(lru, "a") == "avalue"
    assert Lru.get(lru, "b") == "bvalue"
    assert Lru.get(lru, "c") == "cvalue"

    lru = Lru.insert(lru, "a", "avalue2")

    assert Lru.size(lru) == 3
    assert Lru.get(lru, "a") == "avalue2"
    assert Lru.get(lru, "b") == "bvalue"
    assert Lru.get(lru, "c") == "cvalue"
  end
end
