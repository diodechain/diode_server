# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
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
    assert Chain.final_block() |> Block.number() == Chain.window_size() - 1
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
