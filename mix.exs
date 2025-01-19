# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

if String.to_integer(System.otp_release()) < 25 do
  IO.puts("this package requires OTP 25.")
  raise "incorrect OTP"
end

defmodule Diode.Mixfile do
  use Mix.Project

  @vsn "1.6.4"
  @full_vsn "v1.6.4"
  @url "https://github.com/diodechain/diode_server"

  def project do
    [
      aliases: aliases(),
      app: Diode,
      compilers: [:elixir_make] ++ Mix.compilers(),
      deps: deps(),
      description: "Diode Network Full Blockchain Node implementation",
      docs: docs(),
      elixir: "~> 1.13",
      elixirc_options: [warnings_as_errors: Mix.target() == :host],
      elixirc_paths: elixirc_paths(Mix.env()),
      full_version: :persistent_term.get(:full_vsn, @full_vsn),
      package: package(),
      source_url: @url,
      start_permanent: Mix.env() == :prod,
      version: :persistent_term.get(:vsn, @vsn)
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/helpers"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      mod: {Diode, []},
      extra_applications: [
        :debouncer,
        :keccakf1600,
        :libsecp256k1,
        :logger,
        :mix,
        :observer,
        :runtime_tools,
        :sqlitex,
        :os_mon
      ]
    ]
  end

  defp aliases do
    [
      lint: [
        "compile",
        "format --check-formatted",
        "credo --only warning",
        "dialyzer"
      ]
    ]
  end

  defp docs do
    [
      source_ref: "v#{@vsn}",
      source_url: @url,
      formatters: ["html"],
      main: "readme",
      extra_section: "GUIDES",
      extras: [
        LICENSE: [title: "License"],
        "README.md": [title: "Readme"],
        "guides/running_your_miner.md": [title: "Running your miner"]
      ]
    ]
  end

  defp package do
    [
      maintainers: ["Dominic Letz"],
      licenses: ["DIODE"],
      links: %{github: @url},
      files: ~w(evm lib LICENSE mix.exs README.md)
    ]
  end

  defp deps do
    [
      {:dets_plus, "~> 2.0"},
      {:benchee, "~> 1.0", only: :benchmark},
      {:debouncer, "~> 0.1"},
      {:eblake2, "~> 1.0"},
      {:elixir_make, "~> 0.4", runtime: false},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:httpoison, "~> 2.0"},
      {:keccakf1600, github: "diodechain/erlang-keccakf1600"},
      {:libsecp256k1, github: "diodechain/libsecp256k1"},
      {:niffler, "~> 0.1"},
      {:oncrash, "~> 0.0"},
      {:plug_cowboy, "~> 2.5"},
      {:poison, "~> 4.0"},
      {:profiler, github: "dominicletz/profiler"},
      {:sqlitex, github: "diodechain/sqlitex"},
      {:websockex, github: "Azolo/websockex"},
      {:while, "~> 0.2"},
      {:mutable_map, "~> 1.0"},
      # {:mutable_map, path: "../../mutable_map"},

      # linting
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false}
    ]
  end
end
