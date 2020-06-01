# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule OnCrash do
  @spec call(pid() | nil, (reason -> any())) :: true when reason: any()
  def call(pid \\ nil, fun) do
    pid = if pid == nil, do: self(), else: pid

    spawn(fn ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, reason} -> fun.(reason)
      end
    end)

    true
  end
end
