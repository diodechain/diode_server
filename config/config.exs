# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
import Config

# Configures Elixir's Logger
config :logger,
  backends: [:console],
  truncate: 8000,
  format: "$time $metadata[$level] $message"

config :logger, :console, format: "$time $metadata[$level] $message\n"

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
