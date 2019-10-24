defmodule Diode.Mixfile do
  use Mix.Project

  def project do
    [
      app: Diode,
      version: "0.0.1",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers()
    ]
  end

  def application do
    [
      mod: {Diode, []},
      applications: [:cowboy, :plug, :poison],
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 1.0.0"},
      {:plug, "~> 1.0"},
      {:poison, "~> 3.0"},
      {:libsecp256k1, "~> 0.1.10"},
      {:keccakf1600, "~> 2.0", hex: :keccakf1600_orig},
      {:elixir_make, "~> 0.4", runtime: false}
    ]
  end
end
