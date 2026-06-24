defmodule AutoresumeDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :autoresume_demo,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [mod: {AutoresumeDemo.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Normandy declares horde/ecto_sql/postgrex as OPTIONAL, so the demo must
  # declare them itself to pull them into the dependency tree.
  defp deps do
    [
      {:normandy, path: "../.."},
      {:horde, "~> 0.9"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
