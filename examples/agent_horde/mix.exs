defmodule AgentHorde.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_horde,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [{:normandy, path: "../../"}, {:claudio, "~> 0.5.0"}, {:req, "~> 0.5"}, {:jason, "~> 1.4"}]
  end
end
