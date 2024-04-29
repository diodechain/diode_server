# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule BlockQuickTest do
  use ExUnit.Case, async: false
  alias Chain.Block

  setup_all do
    Chain.reset_state()
    :ok
  end

  test "forced stop" do
    target_size = Chain.window_size() * 2
    build(target_size)
    assert Chain.with_final(&Block.number/1) == Chain.window_size() - 1
    assert Chain.peak() == target_size - 11
  end

  defp build(0) do
    :ok
  end

  defp build(n) do
    Chain.Worker.work()
    build(n - 1)
  end
end
