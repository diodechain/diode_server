# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Moonbeam.Sup do
  # Automatically defines child_spec/1
  use Supervisor

  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_args) do
    Supervisor.init([Moonbeam.NonceProvider, Moonbeam.RPCCache], strategy: :one_for_one)
  end
end
