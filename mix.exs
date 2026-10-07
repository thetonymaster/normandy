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
      # decimal arrives only with the optional ecto/postgrex deps and the test-only ex_mcp; its
      # fix (3.0.0) is blocked by ex_json_schema 0.11.3 (via ex_mcp), which requires `decimal ~> 2.0`.
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
      # test/fixtures holds data and the script that generates it, not tests: without this,
      # `mix test` warns that they match no :test_load_filters.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],

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
          "docs/guides/distributed_sessions.md",
          "docs/guides/agent-memory.md",
          "docs/guides/hooks.md"
          # TODO: Add guides
          # "guides/getting_started.md",
          # "guides/multi_agent_coordination.md",
          # "guides/dsl_guide.md"
        ],
        groups_for_extras: [
          Guides: ~r{docs/guides/.*},
          "Upgrading and changes": ["MIGRATING-2.0.md", "CHANGELOG.md"]
        ],
        # Every module with docs is in exactly one group (test/docs/docs_groups_test.exs).
        groups_for_modules: [
          Core: [
            Normandy,
            Normandy.Schema,
            Normandy.Schema.Wire,
            Normandy.Schema.Introspection,
            Normandy.Schema.Validator,
            Normandy.Type,
            Normandy.Validate,
            Normandy.ParameterizedType,
            Normandy.JSON,
            Normandy.Metadata
          ],
          Agents: [
            Normandy.Agents.BaseAgent,
            Normandy.Agents.BaseAgentConfig,
            Normandy.Agents.BaseAgentInputSchema,
            Normandy.Agents.BaseAgentOutputSchema,
            Normandy.Agents.ConfigTemplate,
            Normandy.Agents.Model,
            Normandy.Agents.ToolCallResponse,
            Normandy.Options
          ],
          "Durable turns": [
            Normandy.Agents.Turn,
            Normandy.Agents.Turn.State,
            Normandy.Agents.Turn.Session,
            Normandy.Agents.Turn.Server,
            Normandy.Agents.Turn.Supervisor,
            Normandy.Agents.Turn.Supervisor.Horde,
            Normandy.Agents.Turn.ResumeReaper,
            Normandy.Agents.Turn.Driver.Handlers,
            Normandy.Cluster
          ],
          "Session stores and registries": [
            Normandy.Behaviours.SessionStore,
            Normandy.Behaviours.SessionStore.InMemory,
            Normandy.Behaviours.SessionStore.ETS,
            Normandy.Behaviours.SessionStore.Mnesia,
            Normandy.Behaviours.SessionStore.Postgres,
            Normandy.Behaviours.SessionStore.Postgres.Migration,
            Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate,
            Normandy.Behaviours.SessionStore.Postgres.MigrationAddResumePolicy,
            Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight,
            Normandy.Behaviours.SessionStore.Redis,
            Normandy.Behaviours.SessionRegistry,
            Normandy.Behaviours.SessionRegistry.Native,
            Normandy.Behaviours.SessionRegistry.Horde,
            Normandy.Behaviours.SessionRegistry.Redis,
            Normandy.Behaviours.SessionRegistry.Redis.Handle
          ],
          Memory: [
            Normandy.Tools.Memory,
            Normandy.Behaviours.MemoryStore,
            Normandy.Behaviours.MemoryStore.InMemory,
            Normandy.Behaviours.MemoryStore.ETS,
            Normandy.Behaviours.MemoryStore.Mnesia,
            Normandy.Behaviours.MemoryStore.Postgres,
            Normandy.Behaviours.MemoryStore.Postgres.Migration,
            Normandy.Behaviours.MemoryStore.Redis
          ],
          Hooks: [
            Normandy.Behaviours.Hooks,
            Normandy.Hooks.Context
          ],
          Behaviours: [
            Normandy.Behaviours.Config,
            Normandy.Behaviours.AgentTemplate,
            Normandy.Behaviours.AgentTemplate.Catalog,
            Normandy.Behaviours.BudgetTracker,
            Normandy.Behaviours.BudgetTracker.NoOp,
            Normandy.Behaviours.Compactor,
            Normandy.Behaviours.Compactor.NoOp,
            Normandy.Behaviours.Compactor.WindowManager,
            Normandy.Behaviours.CredentialProvider,
            Normandy.Behaviours.CredentialProvider.FromClient,
            Normandy.Behaviours.ModelCatalog,
            Normandy.Behaviours.ModelCatalog.ModelsAPI,
            Normandy.Behaviours.ModelCatalog.Static,
            Normandy.Behaviours.PolicyEngine,
            Normandy.Behaviours.PolicyEngine.AllowAll,
            Normandy.Behaviours.PolicyEngine.Ruleset
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
            Normandy.Coordination.Orchestration,
            Normandy.Coordination.HierarchicalCoordinator,
            Normandy.Coordination.AgentProcess,
            Normandy.Coordination.AgentSupervisor,
            Normandy.Coordination.AgentMessage,
            Normandy.Coordination.SharedContext,
            Normandy.Coordination.StatefulContext
          ],
          Components: [
            Normandy.Components.AgentMemory,
            Normandy.Components.AgentMemory.Entry,
            Normandy.Components.Message,
            Normandy.Components.ContentBlock.Text,
            Normandy.Components.ContentBlock.Image,
            Normandy.Components.ContentBlock.Document,
            Normandy.Components.PromptSpecification,
            Normandy.Components.SystemPromptGenerator,
            Normandy.Components.BaseIOSchema,
            Normandy.Components.ContextProvider,
            Normandy.Components.DateTimeProvider,
            Normandy.Components.StreamEvent,
            Normandy.Components.StreamProcessor,
            Normandy.Components.ToolCall,
            Normandy.Components.ToolResult
          ],
          Tools: [
            Normandy.Tool,
            Normandy.Tools.Toolset,
            Normandy.Tools.Context,
            Normandy.Tools.Input,
            Normandy.Tools.Executor,
            Normandy.Agents.Dispatch,
            Normandy.Agents.Dispatch.Invocation,
            Normandy.Agents.Dispatch.Pipeline
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
            Normandy.Guardrails.Builtins.RequiredFields,
            Normandy.Guardrails.Builtins.SemanticScope
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
            Normandy.LLM.Request,
            Normandy.LLM.Response,
            Normandy.LLM.ClaudioAdapter,
            Normandy.LLM.OpenAICompatibleAdapter,
            Normandy.LLM.StructuredOutputs,
            Normandy.LLM.JsonDeserializer
          ],
          # Test helpers that ship in the package (Normandy.Test.*): a scripted model client
          # and the contract suites a custom store or registry runs.
          Testing: [
            Normandy.Test.FakeClient,
            Normandy.Test.FakeClient.ScriptExhaustedError,
            Normandy.Test.SessionStoreContract,
            Normandy.Test.MemoryStoreContract,
            Normandy.Test.SessionRegistryContract
          ],
          Errors: [
            Normandy.LLMError,
            Normandy.TurnError,
            Normandy.OrchestrationError,
            Normandy.ToolNotFoundError,
            Normandy.TurnNotFoundError,
            Normandy.ContextProviderNotFoundError,
            Normandy.HookHaltError,
            Normandy.ModelCatalogError,
            Normandy.Schema.ValidationError,
            Normandy.CastError,
            Normandy.InvalidChangesetError,
            Normandy.Guardrails.GuardError
          ],
          Telemetry: [
            Normandy.Telemetry,
            Normandy.Telemetry.Span,
            Normandy.Telemetry.Request,
            Normandy.Telemetry.Usage
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
      mod: {Normandy.Application, []},
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
      {:telemetry, "~> 1.3"},
      {:claudio, "~> 0.7.0"},
      {:req, "~> 0.6 and >= 0.6.1"},
      {:jason, "~> 1.4"},
      # Option schemas for every public entry point (Normandy.Options).
      {:nimble_options, "~> 1.1"},
      {:bypass, "~> 2.1", only: :test},
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
      # SessionRegistry.Horde.Via relies on Horde 0.10's registration order (decision 26a).
      {:horde, "~> 0.10", optional: true},
      {:redix, "~> 1.5", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:opentelemetry, "~> 1.5", only: :test},
      {:opentelemetry_api, "~> 1.4", only: :test},
      # OTLP export for `NORMANDY_E2E_OTLP=1 mix e2e` (e2e/otel_bridge.exs).
      {:opentelemetry_exporter, "~> 1.8", only: :test}
    ] ++ e2e_deps()
  end

  # Live e2e scenario 12 talks to a real stdio MCP server through Claudio's ExMCP adapter.
  # ex_mcp requires Elixir ~> 1.17; on older toolchains (CI's 1.15/1.16 legs) it is left
  # out and only that scenario is unavailable.
  defp e2e_deps do
    if Version.match?(System.version(), "~> 1.17"),
      do: [{:ex_mcp, "~> 1.5", only: :test}],
      else: []
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
        "GitHub" => "https://github.com/thetonymaster/normandy",
        "Changelog" => "https://github.com/thetonymaster/normandy/blob/main/CHANGELOG.md"
      },
      maintainers: ["Antonio Cabrera"],
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      exclude_patterns: [
        "priv/plts",
        "priv/plts/*",
        "priv/test_repo",
        "priv/test_repo/*"
      ]
    ]
  end
end
