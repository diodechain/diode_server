# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Status do
  @moduledoc false

  @shared_state_warn 10_000
  @run_queue_warn 1_000

  def summary do
    {locked, orphans, shared_states, nif_resources, _lazy, _eager} = CMerkleTree.nif_stats()
    memory = :erlang.memory()
    run_queue = Diode.run_queue_total()

    %{
      status: health(shared_states, orphans, run_queue),
      node: node() |> Atom.to_string(),
      uptime_ms: Diode.uptime(),
      version: Diode.version(),
      chain_peak: safe_peak(),
      schedulers: %{
        online: :erlang.system_info(:schedulers_online),
        run_queue: run_queue,
        process_count: :erlang.system_info(:process_count)
      },
      memory: %{
        total: memory[:total],
        processes: memory[:processes],
        system: memory[:system]
      },
      nif: %{
        locked_states: locked,
        orphan_shared_states: orphans,
        shared_states: shared_states,
        merkletree_resources: nif_resources
      }
    }
  end

  defp safe_peak do
    Chain.peak()
  catch
    :exit, {:noproc, _} -> nil
    :exit, _ -> nil
  end

  defp health(shared_states, orphans, run_queue) do
    cond do
      orphans > 0 -> "degraded"
      shared_states >= @shared_state_warn -> "degraded"
      run_queue > @run_queue_warn -> "degraded"
      true -> "ok"
    end
  end
end
