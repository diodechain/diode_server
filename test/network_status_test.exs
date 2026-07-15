# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.StatusTest do
  use ExUnit.Case, async: false

  test "summary includes expected monitor fields" do
    summary = Network.Status.summary()

    assert summary.status in ["ok", "degraded"]
    assert is_binary(summary.node)
    assert is_integer(summary.uptime_ms)
    assert is_binary(summary.version)
    assert summary.chain_peak == nil or is_integer(summary.chain_peak)

    assert %{locked_states: _, orphan_shared_states: _, shared_states: _, merkletree_resources: _} =
             summary.nif

    assert %{online: _, run_queue: _, process_count: _} = summary.schedulers
    assert %{total: _, processes: _, system: _} = summary.memory
  end
end
