# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Diode.Mixfile do
  use Mix.Project

  @vsn "0.3.1"
  @full_vsn "v0.3.1-3"

  def project do
    [
      app: Diode,
      version: :persistent_term.get(:vsn, @vsn),
      full_version: :persistent_term.get(:full_vsn, @full_vsn),
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

  defp deps do
    [
      {:benchee, "~> 1.0", only: :benchmark},
      {:debouncer, "~> 0.1"},
      {:elixir_make, "~> 0.4", runtime: false},
      {:ex_doc, "~> 0.21.2", only: :dev, runtime: false},
      {:keccakf1600, "~> 2.0", github: "hayesgm/erlang-keccakf1600"},
      {:libsecp256k1, "~> 0.1.10"},
      {:plug_cowboy, "~> 1.0.0"},
      {:plug, "~> 1.0"},
      {:poison, "~> 3.0"},
      {:profiler, "~> 0.1"},
      {:sqlitex, github: "diodechain/sqlitex"},
      {:while, "~> 0.2"}
    ]
  end
end
