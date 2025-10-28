defmodule CustomerSupport.MixProject do
  use Mix.Project

  def project do
    [
      app: :customer_support,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {CustomerSupport.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:normandy, path: "../../"},
      {:claudio, "~> 0.1.1"}
    ]
  end
end
