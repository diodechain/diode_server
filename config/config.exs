# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
use Mix.Config

config :kernel,
  start_pg2: true

# Configures Elixir's Logger
config :logger,
  backends: [:console],
  truncate: :infinity,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

case Mix.env() do
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
