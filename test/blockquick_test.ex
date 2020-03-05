# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule BlockQuickTest do
  use ExUnit.Case, async: false

  setup_all do
    Chain.reset_state()
    :ok
  end

  test "forced stop" do
    final = Chain.final_block()
    build(Chain.window_size() + 10, final)
    assert Chain.peak() == Chain.window_size() - 10
  end

  defp build(0, _final) do
    :ok
  end

  defp build(n, final) do
    Chain.Worker.work()
    assert final == Chain.final_block()
    build(n - 1, final)
  end
end
