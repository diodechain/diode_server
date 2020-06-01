# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
use Mix.Config

# Configures Elixir's Logger
config :logger,
  backends: [:console],
  truncate: :infinity,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

case Mix.env() do
  :benchmark ->
    System.put_env("SEED", "none")
    System.put_env("WORKER_MODE", "disabled")

  :test ->
    System.put_env("SEED", "none")
    System.put_env("WORKER_MODE", "poll")

    if System.get_env("RPC_PORT") == nil do
      System.put_env("RPC_PORT", "18001")
      System.put_env("EDGE2_PORT", "18003")
      System.put_env("PEER_PORT", "18004")
    end

  :dev ->
    System.put_env("WORKER_MODE", "poll")
    System.put_env("SEED", "none")

  _env ->
    :ok
end

if Mix.env() != :test and File.exists?("config/diode.exs") do
  import_config "diode.exs"
end
