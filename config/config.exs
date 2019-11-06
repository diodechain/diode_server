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
    System.put_env("WORKER_MODE", "disabled")

  :test ->
    System.put_env("KADEMLIA_PORT", "51053")
    System.put_env("SEED", "diode://localhost:51052")
    System.put_env("WORKER_MODE", "poll")
    System.put_env("DATADIR", "testdata")

  :dev ->
    System.put_env("WORKER_MODE", "poll")
    System.put_env("SEED", "diode://localhost:51052")

  _env ->
    :ok
end

if File.exists?("config/diode.exs") do
  import_config "diode.exs"
end
