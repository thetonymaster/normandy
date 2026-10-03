defmodule Normandy.Agents.ConfigTemplateTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.{BaseAgentConfig, ConfigTemplate}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.AgentMemory

  test "from_config produces a serializable, secret-free template" do
    config = %BaseAgentConfig{
      model: "claude-x",
      temperature: 0.3,
      max_tokens: 100,
      max_tool_iterations: 4,
      max_tool_concurrency: 2,
      name: "support",
      prompt_specification: %Normandy.Components.PromptSpecification{},
      input_schema: SomeInput,
      output_schema: SomeOutput,
      client: %{api_key: "SECRET", base_url: "https://api"},
      tool_registry: %Normandy.Tools.Registry{tools: %{"t" => %{}}},
      behaviours: %Config{before_hooks: [fn _, _ -> :x end]}
    }

    tmpl = ConfigTemplate.from_config(config, "support-agent")

    assert tmpl.template_id == "support-agent"
    assert tmpl.model == "claude-x"
    refute Map.has_key?(tmpl, :client)
    refute Map.has_key?(tmpl, :tool_registry)
    # max_messages nil when memory has no cap configured
    assert tmpl.max_messages == nil
    # term_to_binary must succeed: no closures, no pids.
    assert is_binary(:erlang.term_to_binary(tmpl))
  end

  test "from_config carries the configured memory cap into max_messages" do
    config = %BaseAgentConfig{
      model: "claude-x",
      temperature: 0.3,
      max_tokens: 100,
      max_tool_iterations: 4,
      max_tool_concurrency: 2,
      name: "support",
      prompt_specification: %Normandy.Components.PromptSpecification{},
      input_schema: SomeInput,
      output_schema: SomeOutput,
      memory: AgentMemory.new_memory(42),
      client: %{api_key: "SECRET", base_url: "https://api"},
      tool_registry: %Normandy.Tools.Registry{tools: %{"t" => %{}}},
      behaviours: %Config{}
    }

    tmpl = ConfigTemplate.from_config(config, "capped-agent")

    assert tmpl.max_messages == 42
  end

  test "rebuild uses the template's max_messages to create capped memory" do
    tmpl = %{
      template_id: "support-agent",
      model: "claude-x",
      temperature: 0.3,
      max_tokens: 100,
      max_tool_iterations: 4,
      max_tool_concurrency: 2,
      name: "support",
      max_messages: 5,
      prompt_specification: %Normandy.Components.PromptSpecification{},
      input_schema: SomeInput,
      output_schema: SomeOutput,
      behaviours_refs: %{
        policy: {Normandy.Behaviours.PolicyEngine.AllowAll, []},
        budget: {Normandy.Behaviours.BudgetTracker.NoOp, []},
        credential: {Normandy.Behaviours.CredentialProvider.FromClient, []},
        compactor: {Normandy.Behaviours.Compactor.NoOp, []},
        model_catalog: {Normandy.Behaviours.ModelCatalog.ModelsAPI, []},
        session_store: {Normandy.Behaviours.SessionStore.InMemory, []},
        session_registry: {Normandy.Behaviours.SessionRegistry.Native, []}
      }
    }

    supp = %{
      tool_registry: %Normandy.Tools.Registry{tools: %{}},
      before_hooks: [],
      after_hooks: [],
      client_builder: fn token -> %{api_key: token} end
    }

    config = ConfigTemplate.rebuild(tmpl, supp, "TOKEN")

    assert config.memory.max_messages == 5
  end

  test "rebuild merges template + supplement + token into a full config" do
    tmpl = %{
      template_id: "support-agent",
      model: "claude-x",
      temperature: 0.3,
      max_tokens: 100,
      max_tool_iterations: 4,
      max_tool_concurrency: 2,
      name: "support",
      prompt_specification: %Normandy.Components.PromptSpecification{},
      input_schema: SomeInput,
      output_schema: SomeOutput,
      behaviours_refs: %{
        policy: {Normandy.Behaviours.PolicyEngine.AllowAll, []},
        budget: {Normandy.Behaviours.BudgetTracker.NoOp, []},
        credential: {Normandy.Behaviours.CredentialProvider.FromClient, []},
        compactor: {Normandy.Behaviours.Compactor.NoOp, []},
        model_catalog: {Normandy.Behaviours.ModelCatalog.ModelsAPI, []},
        session_store: {Normandy.Behaviours.SessionStore.InMemory, []},
        session_registry: {Normandy.Behaviours.SessionRegistry.Native, []}
      }
    }

    tr = %Normandy.Tools.Registry{tools: %{"t" => %{}}}

    supp = %{
      tool_registry: tr,
      before_hooks: [:bh],
      after_hooks: [:ah],
      client_builder: fn token -> %{api_key: token, base_url: "https://api"} end
    }

    config = ConfigTemplate.rebuild(tmpl, supp, "TOKEN")

    assert config.model == "claude-x"
    assert config.tool_registry == tr
    assert config.client.api_key == "TOKEN"
    assert config.behaviours.before_hooks == [:bh]
    assert config.behaviours.policy == {Normandy.Behaviours.PolicyEngine.AllowAll, []}
  end

  describe "round trip" do
    defp round_trip_supplement(extra \\ %{}) do
      Map.merge(
        %{
          tool_registry: %Normandy.Tools.Registry{tools: %{}},
          before_hooks: [:bh],
          after_hooks: [:ah],
          client_builder: fn token -> %{api_key: token} end
        },
        extra
      )
    end

    # Everything a template can carry set away from its default, plus the
    # node-local fields set to what the supplement will rebuild.
    defp full_config(supp) do
      %BaseAgentConfig{
        model: "claude-x",
        temperature: 0.3,
        max_tokens: 100,
        max_tool_iterations: 4,
        max_tool_concurrency: 2,
        name: "support",
        prompt_specification: %Normandy.Components.PromptSpecification{background: ["bg"]},
        input_schema: SomeInput,
        output_schema: SomeOutput,
        memory: AgentMemory.new_memory(7),
        initial_memory: AgentMemory.add_message(AgentMemory.new_memory(7), "user", "seed"),
        retry_options: [max_attempts: 4, base_delay: 10],
        enable_json_retry: true,
        json_retry_max_attempts: 5,
        input_guardrails: [SomeGuard, {OtherGuard, [limit: 3]}],
        output_guardrails: [{OutGuard, []}],
        output_guardrails_streaming_mode: :incremental,
        output_guardrails_chunk_size: 64,
        output_guardrails_on_violation: :warn,
        tool_context: %{memory_namespace: "acme/u-1"},
        client: supp.client_builder.("TOKEN"),
        tool_registry: supp.tool_registry,
        behaviours: %Config{before_hooks: supp.before_hooks, after_hooks: supp.after_hooks}
      }
    end

    test "tool_context travels in the template" do
      supp = round_trip_supplement()
      config = %{full_config(supp) | tool_context: %{memory_namespace: "acme/u-7"}}

      tmpl = ConfigTemplate.from_config(config, "t")

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").tool_context ==
               %{memory_namespace: "acme/u-7"}
    end

    test "a template saved before tool_context existed rebuilds with %{}" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t") |> Map.delete(:tool_context)

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").tool_context == %{}
    end

    test "from_config refuses a pid in tool_context" do
      config = %{full_config(round_trip_supplement()) | tool_context: %{owner: self()}}

      assert_raise ArgumentError, ~r/:tool_context/, fn ->
        ConfigTemplate.from_config(config, "t")
      end
    end

    test "rebuild(from_config(c)) gives back c" do
      supp = round_trip_supplement()
      config = full_config(supp)

      tmpl = ConfigTemplate.from_config(config, "support-agent")
      assert is_binary(:erlang.term_to_binary(tmpl))

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN") == config
    end

    test "the circuit breaker and MCP servers come from the supplement, not the template" do
      cb = spawn(fn -> :ok end)

      servers = [
        %Normandy.MCP.ServerConfig{
          name: "docs",
          url: "https://mcp",
          authorization_token: "MCP-SECRET"
        }
      ]

      supp = round_trip_supplement(%{circuit_breaker: cb, mcp_servers: servers})
      config = %{full_config(supp) | circuit_breaker: cb, mcp_servers: servers}

      tmpl = ConfigTemplate.from_config(config, "t")
      blob = :erlang.term_to_binary(tmpl)
      refute blob =~ "MCP-SECRET"
      refute tmpl |> Map.values() |> Enum.any?(&is_pid/1)

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN") == config
    end

    test "rebuild raises when the template had a circuit breaker and the supplement has none" do
      supp = round_trip_supplement()
      tmpl = ConfigTemplate.from_config(%{full_config(supp) | circuit_breaker: self()}, "t")

      assert_raise ArgumentError, ~r/:circuit_breaker/, fn ->
        ConfigTemplate.rebuild(tmpl, supp, "TOKEN")
      end
    end

    test "rebuild raises when the template had MCP servers and the supplement has none" do
      supp = round_trip_supplement()
      servers = [%Normandy.MCP.ServerConfig{name: "docs", url: "https://mcp"}]
      tmpl = ConfigTemplate.from_config(%{full_config(supp) | mcp_servers: servers}, "t")

      assert_raise ArgumentError, ~r/:mcp_servers/, fn ->
        ConfigTemplate.rebuild(tmpl, supp, "TOKEN")
      end
    end

    test "from_config refuses a function in retry_options" do
      config = %{
        full_config(round_trip_supplement())
        | retry_options: [retry_if: fn _ -> true end]
      }

      assert_raise ArgumentError, ~r/from_config\/2.*:retry_options.*function/, fn ->
        ConfigTemplate.from_config(config, "t")
      end
    end

    test "from_config refuses a function in guardrail options" do
      config = %{
        full_config(round_trip_supplement())
        | input_guardrails: [{SomeGuard, [check: fn _ -> :ok end]}]
      }

      assert_raise ArgumentError, ~r/:input_guardrails/, fn ->
        ConfigTemplate.from_config(config, "t")
      end
    end
  end

  test "a 1.x template naming ModelCatalog.Static still decodes with [:safe] (D18)" do
    # :erlang.term_to_binary({Normandy.Behaviours.ModelCatalog.Static, []}) as a
    # 1.x store wrote it. A binary literal, and no test module names the atom, so
    # [:safe] succeeds only because the stub module exists in the app.
    blob =
      <<131, 104, 2, 119, 46, 69, 108, 105, 120, 105, 114, 46, 78, 111, 114, 109, 97, 110, 100,
        121, 46, 66, 101, 104, 97, 118, 105, 111, 117, 114, 115, 46, 77, 111, 100, 101, 108, 67,
        97, 116, 97, 108, 111, 103, 46, 83, 116, 97, 116, 105, 99, 106>>

    assert {mod, []} = :erlang.binary_to_term(blob, [:safe])
    assert Atom.to_string(mod) == "Elixir.Normandy.Behaviours.ModelCatalog.Static"
    Code.ensure_loaded!(mod)
  end

  test "rebuild rejects an unsizable compaction setup (non-Claudio client, unpinned compactor)" do
    tmpl = %{
      template_id: "t",
      model: "m",
      temperature: nil,
      max_tokens: 100,
      max_tool_iterations: 4,
      max_tool_concurrency: 1,
      name: "n",
      prompt_specification: %Normandy.Components.PromptSpecification{},
      input_schema: nil,
      output_schema: nil,
      behaviours_refs: %{
        policy: {Normandy.Behaviours.PolicyEngine.AllowAll, []},
        budget: {Normandy.Behaviours.BudgetTracker.NoOp, []},
        credential: {Normandy.Behaviours.CredentialProvider.FromClient, []},
        compactor: {Normandy.Behaviours.Compactor.WindowManager, [reserved_tokens: 16]},
        model_catalog: {Normandy.Behaviours.ModelCatalog.ModelsAPI, []},
        session_store: {Normandy.Behaviours.SessionStore.InMemory, []},
        session_registry: {Normandy.Behaviours.SessionRegistry.Native, []}
      }
    }

    supp = %{
      tool_registry: nil,
      before_hooks: [],
      after_hooks: [],
      client_builder: fn token -> %{api_key: token} end
    }

    assert_raise ArgumentError, ~r/:max_tokens/, fn -> ConfigTemplate.rebuild(tmpl, supp, "T") end

    pinned =
      put_in(
        tmpl.behaviours_refs.compactor,
        {Normandy.Behaviours.Compactor.WindowManager, [max_tokens: 50_000]}
      )

    assert %Normandy.Agents.BaseAgentConfig{} = ConfigTemplate.rebuild(pinned, supp, "T")
  end

  test "rebuild raises for a ClaudioAdapter client with invalid options" do
    tmpl = %{
      template_id: "T",
      model: "claude-x",
      temperature: 0.3,
      max_tokens: 100,
      max_tool_iterations: 4,
      max_tool_concurrency: 2,
      name: "n",
      prompt_specification: %Normandy.Components.PromptSpecification{},
      input_schema: nil,
      output_schema: nil,
      behaviours_refs: %{
        policy: {Normandy.Behaviours.PolicyEngine.AllowAll, []},
        budget: {Normandy.Behaviours.BudgetTracker.NoOp, []},
        credential: {Normandy.Behaviours.CredentialProvider.FromClient, []},
        compactor: {Normandy.Behaviours.Compactor.NoOp, []},
        model_catalog: {Normandy.Behaviours.ModelCatalog.ModelsAPI, []},
        session_store: {Normandy.Behaviours.SessionStore.InMemory, []},
        session_registry: {Normandy.Behaviours.SessionRegistry.Native, []}
      }
    }

    build = fn options ->
      %{
        tool_registry: nil,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn token ->
          %Normandy.LLM.ClaudioAdapter{api_key: token, options: options}
        end
      }
    end

    error =
      assert_raise ArgumentError, fn ->
        ConfigTemplate.rebuild(
          tmpl,
          build.(%{thinking: :adaptive, thinking_budget: 1}),
          "sk-secret"
        )
      end

    refute error.message =~ "sk-secret"
    assert %BaseAgentConfig{} = ConfigTemplate.rebuild(tmpl, build.(%{effort: :high}), "T")
  end
end
