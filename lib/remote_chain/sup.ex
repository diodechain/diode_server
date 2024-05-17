# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.Sup do
  # Automatically defines child_spec/1
  use Supervisor

  def start_link(chain, opts \\ []) do
    Supervisor.start_link(__MODULE__, {chain, opts})
  end

  def init({chain, opts}) do
    cache = Keyword.get(opts, :cache) || Lru.new(100_000)

    Supervisor.init(
      [
        {RemoteChain.NodeProxy, chain},
        {RemoteChain.RPCCache, [chain, cache]},
        {RemoteChain.NonceProvider, chain},
        {RemoteChain.TxRelay, chain}
      ],
      strategy: :rest_for_one
    )
  end
end
