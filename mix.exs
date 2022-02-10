# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Diode.Mixfile do
  use Mix.Project

  @vsn "0.5.6"
  @full_vsn "v0.5.6"
  @url "https://github.com/diodechain/diode_server"

  def project do
    [
      app: Diode,
      elixir: "~> 1.11",
      version: :persistent_term.get(:vsn, @vsn),
      full_version: :persistent_term.get(:full_vsn, @full_vsn),
      source_url: @url,
      description: "Diode Network Full Blockchain Node implementation",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: docs(),
      package: package()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/helpers"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      mod: {Diode, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :debouncer,
        :sqlitex,
        :keccakf1600,
        :libsecp256k1,
        :observer
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
      {:benchee, "~> 1.0", only: :benchmark},
      {:debouncer, "~> 0.1"},
      {:elixir_make, "~> 0.4", runtime: false},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:keccakf1600, github: "diodechain/erlang-keccakf1600"},
      {:libsecp256k1, github: "diodechain/libsecp256k1"},
      {:plug_cowboy, "~> 2.5"},
      {:poison, "~> 3.0"},
      {:profiler, github: "dominicletz/profiler"},
      {:sqlitex, github: "diodechain/sqlitex"},
      {:niffler, "~> 0.1"},
      {:while, "~> 0.2"}
    ]
  end
end
