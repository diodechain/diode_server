# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule EtsLruTest do
  use ExUnit.Case

  test "base" do
    lru = EtsLru.new(nil, 10)
    assert EtsLru.size(lru) == 0

    EtsLru.put(lru, "key", "value")
    assert EtsLru.size(lru) == 1

    assert EtsLru.get(lru, "key") == "value"

    # EtsLru should not cache nil return values
    assert EtsLru.fetch(lru, "nothing", fn -> nil end) == nil
    assert EtsLru.fetch(lru, "nothing", fn -> "yay" end) == "yay"
    assert EtsLru.get(lru, "nothing") == "yay"
  end

  test "limit" do
    lru = EtsLru.new(nil, 3)
    assert EtsLru.size(lru) == 0

    EtsLru.put(lru, "a", "avalue")
    EtsLru.put(lru, "b", "bvalue")
    EtsLru.put(lru, "c", "cvalue")

    assert EtsLru.size(lru) == 3
    assert EtsLru.get(lru, "a") == "avalue"
    assert EtsLru.get(lru, "b") == "bvalue"
    assert EtsLru.get(lru, "c") == "cvalue"

    EtsLru.put(lru, "d", "dvalue")

    assert EtsLru.size(lru) == 3
    assert EtsLru.get(lru, "a") == nil
    assert EtsLru.get(lru, "b") == "bvalue"
    assert EtsLru.get(lru, "c") == "cvalue"
    assert EtsLru.get(lru, "d") == "dvalue"
  end

  test "set_max_size" do
    lru = EtsLru.new(nil, 3)
    assert EtsLru.max_size(lru) == 3

    EtsLru.set_max_size(lru, 10)
    assert EtsLru.max_size(lru) == 10
  end

  test "repeat" do
    lru = EtsLru.new(nil, 3)
    assert EtsLru.size(lru) == 0

    EtsLru.put(lru, "a", "avalue")
    EtsLru.put(lru, "b", "bvalue")
    EtsLru.put(lru, "c", "cvalue")

    assert EtsLru.size(lru) == 3
    assert EtsLru.get(lru, "a") == "avalue"
    assert EtsLru.get(lru, "b") == "bvalue"
    assert EtsLru.get(lru, "c") == "cvalue"

    EtsLru.put(lru, "a", "avalue2")

    assert EtsLru.size(lru) == 3
    assert EtsLru.get(lru, "a") == "avalue2"
    assert EtsLru.get(lru, "b") == "bvalue"
    assert EtsLru.get(lru, "c") == "cvalue"
  end
end
