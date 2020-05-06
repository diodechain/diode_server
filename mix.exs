# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Diode.Mixfile do
  use Mix.Project

  def project do
    [
      app: Diode,
      version: "0.0.1",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/helpers"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      mod: {Diode, []},
      applications: [:cowboy, :plug, :poison],
      extra_applications: [:logger, :runtime_tools, :debouncer]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.21.2"},
      {:plug_cowboy, "~> 1.0.0"},
      {:plug, "~> 1.0"},
      {:profiler, "~> 0.1.0"},
      {:poison, "~> 3.0"},
      {:libsecp256k1, "~> 0.1.10"},
      {:keccakf1600, "~> 2.0", hex: :keccakf1600_orig},
      {:elixir_make, "~> 0.4", runtime: false},
      {:benchee, "~> 1.0", only: :benchmark},
      {:debouncer, "~> 0.1"},
      {:while, "~> 0.2"},
      {:sqlitex, github: "diodechain/sqlitex"}
    ]
  end
end
