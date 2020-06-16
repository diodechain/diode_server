# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Diode.Mixfile do
  use Mix.Project

  @vsn "0.2.2"
  @full_vsn "v0.2.2-4-g92db360-dirty"

  def project do
    [
      app: Diode,
      version: :persistent_term.get(:vsn, @vsn),
      full_version: :persistent_term.get(:full_vsn, @full_vsn),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:git_version, :elixir_make] ++ Mix.compilers(),
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
      {:benchee, "~> 1.0", only: :benchmark},
      {:debouncer, "~> 0.1"},
      {:elixir_make, "~> 0.4", runtime: false},
      {:ex_doc, "~> 0.21.2", only: :dev, runtime: false},
      {:keccakf1600, "~> 2.0", hex: :keccakf1600_orig},
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

defmodule Mix.Tasks.Compile.GitVersion do
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    case System.cmd("git", ["describe", "--tags", "--dirty"]) do
      {version, 0} ->
        Regex.run(~r/v([0-9]+\.[0-9]+\.[0-9]+)(-.*)?/, version)
        |> case do
          [full_vsn, vsn, _rest] ->
            :persistent_term.put(:vsn, vsn)

            bin = original = File.read!("mix.exs")
            bin = Regex.replace(~r/\@vsn .*/, bin, "@vsn \"#{vsn}\"", global: false)

            bin =
              Regex.replace(~r/\@full_vsn .*/, bin, "@full_vsn \"#{full_vsn}\"", global: false)

            if bin != original, do: File.write!("mix.exs", bin)

          other ->
            :io.format("Couldn't parse version ~p~n", [other])
        end

      other ->
        :io.format("Couldn't check git version ~p~n", [other])
    end

    Mix.shell().info(Enum.join(args, " "))
  end
end
