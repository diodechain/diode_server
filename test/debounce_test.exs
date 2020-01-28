# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule DebounceTest do
  use ExUnit.Case
  @timeout 500
  @pause 500

  setup_all do
    :debounce_test = :ets.new(:debounce_test, [:named_table, :public])
    :ok
  end

  setup do
    reset()
    :ok
  end

  defp reset() do
    :ets.insert(:debounce_test, {:first, 0})
  end

  defp incr(value) do
    :ets.update_counter(:debounce_test, :first, value, {:first, 0})
  end

  defp get() do
    [{:first, num}] = :ets.lookup(:debounce_test, :first)
    num
  end

  test "apply debounced" do
    Debounce.apply(:test_one, fn -> incr(1) end, @timeout)
    Debounce.apply(:test_one, fn -> incr(3) end, @timeout)
    Debounce.apply(:test_one, fn -> incr(5) end, @timeout)
    Debounce.apply(:test_one, fn -> incr(7) end, @timeout)
    Debounce.apply(:test_one, fn -> incr(11) end, @timeout)
    Process.sleep(@timeout + @pause)
    # Last should be executed
    assert get() == 11
  end

  test "delay debounced" do
    Debounce.delay(:test_two, fn -> incr(1) end, @timeout)
    Debounce.delay(:test_two, fn -> incr(3) end, @timeout)
    Debounce.delay(:test_two, fn -> incr(5) end, @timeout)
    Debounce.delay(:test_two, fn -> incr(7) end, @timeout)
    Debounce.delay(:test_two, fn -> incr(11) end, @timeout)
    Process.sleep(@timeout + @pause)
    # Last should be executed
    assert get() == 11
  end

  test "immediate debounced" do
    Debounce.immediate(:test_three, fn -> incr(1) end, @timeout)
    Debounce.immediate(:test_three, fn -> incr(3) end, @timeout)
    Debounce.immediate(:test_three, fn -> incr(5) end, @timeout)
    Debounce.immediate(:test_three, fn -> incr(7) end, @timeout)
    Debounce.immediate(:test_three, fn -> incr(11) end, @timeout)
    Process.sleep(@timeout + @pause)
    # First and last should be executed
    assert get() == 12
  end

  test "apply twice" do
    for _ <- 1..10 do
      Debounce.apply(:test_one_b, fn -> incr(3) end, @timeout)
      # 100
      Process.sleep(100)
    end

    Process.sleep(@pause)
    assert get() == 6
  end

  test "delay twice" do
    for _ <- 1..10 do
      Debounce.delay(:test_two_b, fn -> incr(3) end, @timeout)
      # 100
      Process.sleep(100)
    end

    Process.sleep(@pause)
    assert get() == 3
  end

  test "immediate twice" do
    for _ <- 1..12 do
      Debounce.immediate(:test_three_b, fn -> incr(3) end, @timeout)
      # 100
      Process.sleep(100)
    end

    Process.sleep(@pause)
    assert get() == 12
  end
end
