defmodule Normandy.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :normandy,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      consolidate_protocols: Mix.env() != :test,
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: dialyzer(),
      test_coverage: [summary: [threshold: 60]],

      # Hex.pm metadata
      description: description(),
      package: package(),
      source_url: "https://github.com/thetonymaster/normandy",
      homepage_url: "https://github.com/thetonymaster/normandy",
      docs: [
        main: "readme",
        # logo: "assets/logo.png",  # TODO: Add logo
        extras: [
          "README.md",
          "CHANGELOG.md",
          "ROADMAP.md"
          # TODO: Add guides
          # "guides/getting_started.md",
          # "guides/multi_agent_coordination.md",
          # "guides/dsl_guide.md"
        ],
        # groups_for_extras: [
        #   "Guides": ~r/guides\/.*/
        # ],
        groups_for_modules: [
          Core: [
            Normandy.Schema,
            Normandy.Type,
            Normandy.Validate,
            Normandy.ParameterizedType
          ],
          Agents: [
            Normandy.Agents.BaseAgent,
            Normandy.Agents.BaseAgentConfig,
            Normandy.Agents.Model,
            Normandy.Agents.IOModel,
            Normandy.Agents.ToolCallResponse
          ],
          DSL: [
            Normandy.DSL.Agent,
            Normandy.DSL.Workflow
          ],
          Coordination: [
            Normandy.Coordination.Pattern,
            Normandy.Coordination.Reactive,
            Normandy.Coordination.AgentPool,
            Normandy.Coordination.SequentialOrchestrator,
            Normandy.Coordination.ParallelOrchestrator,
            Normandy.Coordination.HierarchicalCoordinator,
            Normandy.Coordination.AgentProcess,
            Normandy.Coordination.AgentSupervisor,
            Normandy.Coordination.AgentMessage,
            Normandy.Coordination.SharedContext,
            Normandy.Coordination.StatefulContext
          ],
          Components: [
            Normandy.Components.AgentMemory,
            Normandy.Components.Message,
            Normandy.Components.PromptSpecification,
            Normandy.Components.SystemPromptGenerator,
            Normandy.Components.BaseIOSchema,
            Normandy.Components.ContextProvider,
            Normandy.Components.StreamEvent,
            Normandy.Components.StreamProcessor,
            Normandy.Components.ToolCall,
            Normandy.Components.ToolResult
          ],
          Tools: [
            Normandy.Tools.BaseTool,
            Normandy.Tools.Registry,
            Normandy.Tools.Executor
          ],
          "Context Management": [
            Normandy.Context.TokenCounter,
            Normandy.Context.WindowManager,
            Normandy.Context.Summarizer
          ],
          Resilience: [
            Normandy.Resilience.Retry,
            Normandy.Resilience.CircuitBreaker
          ],
          "Batch Processing": [
            Normandy.Batch.Processor
          ],
          "LLM Adapters": [
            Normandy.LLM.ClaudioAdapter
          ]
        ],
        source_ref: "v#{@version}",
        formatters: ["html"]
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
    Build AI agents with structured schemas, validation, and LLM integration.
    Supports multi-agent coordination, conversational memory, batch processing,
    and resilience patterns for production-ready AI applications.
    """
  end

  defp package do
    [
      name: "normandy",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/thetonymaster/normandy"
      },
      maintainers: ["Antonio Cabrera"],
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      exclude_patterns: [
        "priv/plts",
        "priv/plts/*"
      ]
    ]
  end
end
