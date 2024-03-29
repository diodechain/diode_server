# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.Sup do
  # Automatically defines child_spec/1
  use Supervisor

  def start_link(chain) do
    Supervisor.start_link(__MODULE__, chain)
  end

  def init(chain) do
    Supervisor.init(
      [
        {RemoteChain.RPCCache, chain},
        {RemoteChain.NodeProxy, chain},
        {RemoteChain.NonceProvider, chain}
      ],
      strategy: :one_for_one
    )
  end
end
