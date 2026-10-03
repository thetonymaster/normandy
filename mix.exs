defmodule Normandy.MixProject do
  use Mix.Project

  @version "1.3.0"

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
      # cowlib is test-only (Bypass -> plug_cowboy -> cowboy). 43966 and 43969 have no fix in
      # any release; 43971 is fixed in 2.20.0, which is pinned out (see deps/0: OTP 26).
      # decimal arrives only with the optional ecto/postgrex deps; its fix (3.0.0) is blocked
      # by poison 6.0.0, the latest release, which declares an optional `decimal ~> 2.1`.
      # Hex warns once an entry no longer matches the lock.
      hex: [
        ignore_advisories: [
          "EEF-CVE-2026-43966",
          "EEF-CVE-2026-43969",
          "EEF-CVE-2026-43971",
          "EEF-CVE-2026-32686"
        ]
      ],
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
          "LICENSE",
          "MIGRATING-2.0.md",
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
        # Old entries name functions since removed (e.g. Normandy.Type.load/1); cocogitto
        # owns the file, so its history is not rewritten.
        skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
        source_ref: "v#{@version}",
        formatters: ["html"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # Not :mnesia for consumers (a dependency builds in :prod): OTP starts every
      # listed application, optional ones too when available, and only
      # SessionStore.Mnesia needs it. Apps that use that store add :mnesia
      # themselves; Normandy's own dev and test builds load it here.
      extra_applications: [:logger] ++ if(Mix.env() in [:dev, :test], do: [:mnesia], else: [])
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_uuid, "~> 1.2"},
      {:poison, "~> 6.0"},
      {:telemetry, "~> 1.0"},
      {:claudio, path: "../Claudio"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:bypass, "~> 2.1", only: :test},
      # Live e2e scenario 12 talks to a real stdio MCP server through Claudio's ExMCP adapter.
      {:ex_mcp, "~> 1.5", only: :test},
      # Bypass's server. cowlib 2.20.0 uses `maybe` without enabling the feature, so it
      # fails to compile on OTP 26, which CI still tests. Lift these pins when OTP 26 leaves
      # the matrix.
      {:cowboy, "~> 2.18.0", only: :test},
      {:cowlib, "~> 2.19.0", only: :test},
      # Tier-1/2 session infra. Optional: Tier-0 (default) users pull in none of these.
      # The Postgres/Horde modules are conditionally compiled on their presence.
      {:ecto_sql, "~> 3.12", optional: true},
      # >= 0.22.4: earlier releases carry EEF-CVE-2026-66838 (SQL injection via the
      # :comment option, fixed in 0.22.4) and EEF-CVE-2026-58225 (Notifications reconnect
      # replay, fixed in 0.22.3).
      {:postgrex, "~> 0.22 and >= 0.22.4", optional: true},
      {:horde, "~> 0.9", optional: true},
      {:redix, "~> 1.5", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:opentelemetry, "~> 1.5", only: :test},
      {:opentelemetry_api, "~> 1.4", only: :test}
    ]
  end

  # Run the `test.postgres` alias in the :test env (it invokes `test`).
  def cli do
    [preferred_envs: [precommit: :test, "test.postgres": :test, "test.redis": :test, e2e: :test]]
  end

  defp aliases do
    [
      # DB setup is NOT in the default `test` alias, so `mix test` runs without
      # Postgres (the :postgres tests are excluded by default). Run the durable-store
      # tests with `mix test.postgres` (requires a reachable Postgres) — a function
      # alias so it can flag test_helper to start the Repo (argv only shows the alias
      # name, not the expanded `--include postgres`).
      "ecto.setup": ["ecto.create --quiet", "ecto.migrate --quiet"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format",
        "credo --strict",
        "dialyzer",
        "test --warnings-as-errors"
      ],
      "test.postgres": &run_postgres_tests/1,
      "test.redis": &run_redis_tests/1,
      e2e: ["run e2e/run.exs"]
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
      # Under _build (cached in CI), not priv/: package files include priv/.
      plt_core_path: "_build/plts",
      plt_local_path: "_build/plts",
      plt_add_apps: [:ex_unit, :mnesia],
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
