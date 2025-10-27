defmodule Normandy.MixProject do
  use Mix.Project

  def project do
    [
      app: :normandy,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      consolidate_protocols: Mix.env() != :test,
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: dialyzer(),

      # Hex.pm metadata
      description: description(),
      package: package(),
      source_url: "https://github.com/thetonymaster/normandy",
      homepage_url: "https://github.com/thetonymaster/normandy",
      docs: [
        main: "readme",
        extras: ["README.md", "ROADMAP.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_uuid, "~> 1.2"},
      {:poison, "~> 6.0"},
      {:claudio, "~> 0.1.1"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:ex_unit],
      flags: [:unmatched_returns, :error_handling, :underspecs]
    ]
  end

  defp description do
    """
    Normandy is an Elixir library for building AI agents with structured schemas,
    validation, and LLM integration. It provides a type-safe approach to defining
    agent inputs/outputs using JSON schemas and supports conversational memory
    management, multi-agent coordination, batch processing, and resilience patterns.
    """
  end

  defp package do
    [
      name: "normandy",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/thetonymaster/normandy"
      },
      maintainers: ["Antonio Cabrera"]
    ]
  end
end
