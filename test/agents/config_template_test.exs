defmodule Normandy.Agents.ConfigTemplateTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.{BaseAgentConfig, ConfigTemplate}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.AgentMemory
  alias Normandy.Tools.Toolset

  defmodule OldStyleTool do
    @moduledoc false
    defstruct []
  end

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
      toolset: %Normandy.Tools.Toolset{tools: %{"t" => %{}}},
      behaviours: %Config{before_hooks: [fn _, _ -> :x end]}
    }

    tmpl = ConfigTemplate.from_config(config, "support-agent")

    assert tmpl.template_id == "support-agent"
    assert tmpl.model == "claude-x"
    refute Map.has_key?(tmpl, :client)
    refute Map.has_key?(tmpl, :toolset)
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
      toolset: %Normandy.Tools.Toolset{tools: %{"t" => %{}}},
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
      toolset: %Normandy.Tools.Toolset{tools: %{}},
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

    tr = Toolset.new([%Normandy.Test.FakeTool{name: "t"}])

    supp = %{
      toolset: tr,
      before_hooks: [:bh],
      after_hooks: [:ah],
      client_builder: fn token -> %{api_key: token, base_url: "https://api"} end
    }

    config = ConfigTemplate.rebuild(tmpl, supp, "TOKEN")

    assert config.model == "claude-x"
    assert config.toolset == tr
    assert config.client.api_key == "TOKEN"
    assert config.behaviours.before_hooks == [:bh]
    assert config.behaviours.policy == {Normandy.Behaviours.PolicyEngine.AllowAll, []}
  end

  describe "round trip" do
    defp round_trip_supplement(extra \\ %{}) do
      Map.merge(
        %{
          toolset: %Normandy.Tools.Toolset{tools: %{}},
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
        retry: [max_attempts: 4, base_delay: 10],
        circuit_breaker: [failure_threshold: 3],
        enable_json_retry: true,
        json_retry_max_attempts: 5,
        guardrails: [
          input: [SomeGuard, {OtherGuard, [limit: 3]}],
          output: [{OutGuard, []}],
          streaming_mode: :incremental,
          chunk_size: 64,
          on_violation: :warn
        ],
        tool_context: %{memory_namespace: "acme/u-1"},
        client: supp.client_builder.("TOKEN"),
        toolset: supp.toolset,
        behaviours: %Config{before_hooks: supp.before_hooks, after_hooks: supp.after_hooks}
      }
    end

    test "hooks travel in the template" do
      supp = round_trip_supplement()
      hooks = [{Normandy.Test.Hooks.Probe, tag: :audit, on_error: :open}]
      config = %{full_config(supp) | behaviours: %{full_config(supp).behaviours | hooks: hooks}}

      rebuilt = config |> ConfigTemplate.from_config("t") |> ConfigTemplate.rebuild(supp, "TOKEN")

      assert rebuilt.behaviours.hooks == hooks
    end

    test "a supplement still keyed :tool_registry (1.x) raises, naming the key" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")
      old = supp |> Map.delete(:toolset) |> Map.put(:tool_registry, supp.toolset)

      error = assert_raise ArgumentError, fn -> ConfigTemplate.rebuild(tmpl, old, "TOKEN") end

      assert error.message ==
               "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement has :tool_registry, which 2.0 calls " <>
                 ":toolset (a %Normandy.Tools.Toolset{} or nil); " <>
                 "see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour)"
    end

    test "a supplement toolset holding a 1.x tool raises, naming its module" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")
      bad = %{supp | toolset: %Toolset{tools: %{"old" => %OldStyleTool{}}}}

      error = assert_raise ArgumentError, fn -> ConfigTemplate.rebuild(tmpl, bad, "TOKEN") end

      assert error.message =~
               "Normandy.Agents.ConfigTemplate.rebuild/3: Normandy.Agents.ConfigTemplateTest.OldStyleTool " <>
                 "does not implement the Normandy.Tool behaviour."
    end

    test "a supplement :toolset that is not a Toolset raises" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")

      error =
        assert_raise ArgumentError, fn ->
          ConfigTemplate.rebuild(tmpl, %{supp | toolset: [:tool]}, "TOKEN")
        end

      assert error.message ==
               "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement's :toolset must be a " <>
                 "%Normandy.Tools.Toolset{} or nil, got: a list"
    end

    test "a template saved before hooks existed rebuilds with []" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")
      tmpl = %{tmpl | behaviours_refs: Map.delete(tmpl.behaviours_refs, :hooks)}

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").behaviours.hooks == []
    end

    test "from_config refuses hook opts that are not plain data" do
      supp = round_trip_supplement()
      hooks = [{Normandy.Test.Hooks.Probe, notify: self()}]
      config = %{full_config(supp) | behaviours: %{full_config(supp).behaviours | hooks: hooks}}

      assert_raise ArgumentError, ~r/must be plain data/, fn ->
        ConfigTemplate.from_config(config, "t")
      end
    end

    test "rebuild refuses a template whose hook entries are malformed, naming the hook" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")

      bad = fn hooks -> put_in(tmpl.behaviours_refs.hooks, hooks) end

      assert_raise ArgumentError, ~r/invalid :on_error/, fn ->
        ConfigTemplate.rebuild(
          bad.([{Normandy.Test.Hooks.Probe, on_error: :sometimes}]),
          supp,
          "T"
        )
      end

      assert_raise ArgumentError, ~r/must be plain data/, fn ->
        ConfigTemplate.rebuild(bad.([{Normandy.Test.Hooks.Probe, notify: self()}]), supp, "T")
      end

      assert_raise ArgumentError, ~r/invalid hook entry/, fn ->
        ConfigTemplate.rebuild(bad.([Normandy.Test.Hooks.Probe]), supp, "T")
      end
    end

    test "rebuild does not require a hook module to exist on this node" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")
      tmpl = put_in(tmpl.behaviours_refs.hooks, [{Nope.Missing, []}])

      assert ConfigTemplate.rebuild(tmpl, supp, "T").behaviours.hooks == [{Nope.Missing, []}]
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

    test "MCP servers come from the supplement, not the template" do
      servers = [
        %Normandy.MCP.ServerConfig{
          name: "docs",
          url: "https://mcp",
          authorization_token: "MCP-SECRET"
        }
      ]

      supp = round_trip_supplement(%{mcp_servers: servers})
      config = %{full_config(supp) | mcp_servers: servers}

      tmpl = ConfigTemplate.from_config(config, "t")
      blob = :erlang.term_to_binary(tmpl)
      refute blob =~ "MCP-SECRET"
      refute tmpl |> Map.values() |> Enum.any?(&is_pid/1)

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN") == config
    end

    test "the breaker options travel in the template and need nothing from the supplement" do
      supp = round_trip_supplement()
      config = %{full_config(supp) | circuit_breaker: [failure_threshold: 3, scope: "tenant-a"]}

      tmpl = ConfigTemplate.from_config(config, "t")
      assert tmpl.node_local_fields == []

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").circuit_breaker ==
               [failure_threshold: 3, scope: "tenant-a"]
    end

    test "a template that lists :circuit_breaker_pid (an earlier 2.0 build) raises naming it" do
      supp = round_trip_supplement()
      tmpl = ConfigTemplate.from_config(full_config(supp), "t")
      tmpl = %{tmpl | node_local_fields: [:circuit_breaker_pid]}

      assert_raise ArgumentError, ~r/lists :circuit_breaker_pid in :node_local_fields/, fn ->
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

    test "from_config refuses a function in the retry options" do
      config = %{
        full_config(round_trip_supplement())
        | retry: [retry_if: fn _ -> true end]
      }

      assert_raise ArgumentError, ~r/from_config\/2.*:retry .*function/, fn ->
        ConfigTemplate.from_config(config, "t")
      end
    end

    test "from_config refuses a function in guardrail options" do
      config = %{
        full_config(round_trip_supplement())
        | guardrails: [input: [{SomeGuard, [check: fn _ -> :ok end]}]]
      }

      assert_raise ArgumentError, ~r/from_config\/2: :guardrails contains a function/, fn ->
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
      toolset: nil,
      before_hooks: [],
      after_hooks: [],
      client_builder: fn token -> %{api_key: token} end
    }

    assert_raise ArgumentError, ~r/:context_window/, fn ->
      ConfigTemplate.rebuild(tmpl, supp, "T")
    end

    pinned =
      put_in(
        tmpl.behaviours_refs.compactor,
        {Normandy.Behaviours.Compactor.WindowManager, [context_window: 50_000]}
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
        toolset: nil,
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
