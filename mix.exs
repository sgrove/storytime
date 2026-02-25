defmodule Storytime.MixProject do
  use Mix.Project

  def project do
    [
      app: :storytime,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Storytime.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.4"},
      {:cors_plug, "~> 3.0"},
      {:plug_cowboy, "~> 2.7"},
      {:req, "~> 0.5"},
      {:oban, "~> 2.19"}
    ]
  end
end
