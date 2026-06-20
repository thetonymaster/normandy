defmodule Normandy.MixProject do
  use Mix.Project

  @version "1.1.1"

  def project do
    [
      app: :normandy,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
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
          "ROADMAP.md",
          "docs/guides/distributed_sessions.md"
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
          Guardrails: [
            Normandy.Guardrails,
            Normandy.Guardrails.Guard,
            Normandy.Guardrails.ViolationError,
            Normandy.Guardrails.Builtins.MaxLength,
            Normandy.Guardrails.Builtins.ForbiddenSubstrings,
            Normandy.Guardrails.Builtins.RegexGuard,
            Normandy.Guardrails.Builtins.RequiredFields
          ],
          "Batch Processing": [
            Normandy.Batch.Processor
          ],
          MCP: [
            Normandy.MCP.ToolWrapper,
            Normandy.MCP.Registry,
            Normandy.MCP.ServerConfig
          ],
          A2A: [
            Normandy.A2A.AgentTool,
            Normandy.A2A.Registry,
            Normandy.A2A.Server
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
      extra_applications: [:logger, :mnesia]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_uuid, "~> 1.2"},
      {:poison, "~> 6.0"},
      {:telemetry, "~> 1.0"},
      {:claudio, "~> 0.5.0"},
      # Tier-1/2 session infra. Optional: Tier-0 (default) users pull in none of these.
      # The Postgres/Horde modules are conditionally compiled on their presence.
      {:ecto_sql, "~> 3.12", optional: true},
      {:postgrex, "~> 0.19", optional: true},
      {:horde, "~> 0.9", optional: true},
      {:redix, "~> 1.5", optional: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:opentelemetry, "~> 1.5", only: :test},
      {:opentelemetry_api, "~> 1.4", only: :test}
    ]
  end

  # Run the `test.postgres` alias in the :test env (it invokes `test`).
  def cli do
    [preferred_envs: ["test.postgres": :test, "test.redis": :test]]
  end

  defp aliases do
    [
      # DB setup is NOT in the default `test` alias, so `mix test` runs without
      # Postgres (the :postgres tests are excluded by default). Run the durable-store
      # tests with `mix test.postgres` (requires a reachable Postgres) — a function
      # alias so it can flag test_helper to start the Repo (argv only shows the alias
      # name, not the expanded `--include postgres`).
      "ecto.setup": ["ecto.create --quiet", "ecto.migrate --quiet"],
      "test.postgres": &run_postgres_tests/1,
      "test.redis": &run_redis_tests/1
    ]
  end

  defp run_postgres_tests(args) do
    System.put_env("NORMANDY_POSTGRES", "true")
    Mix.Task.run("ecto.setup")
    Mix.Task.run("test", ["--include", "postgres" | args])
  end

  # No DB setup step (unlike test.postgres): Redis needs no schema/migrations,
  # just a reachable server at :redis_url.
  defp run_redis_tests(args) do
    System.put_env("NORMANDY_REDIS", "true")
    Mix.Task.run("test", ["--include", "redis" | args])
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
    Elixir framework for building production-ready AI agents and LLM applications:
    type-safe schemas with JSON Schema generation, tool calling, streaming,
    multi-agent coordination, guardrails, and distributed fault-tolerant sessions,
    with first-class Anthropic Claude support.
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
