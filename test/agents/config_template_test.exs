defmodule Normandy.Agents.ConfigTemplateTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.{BaseAgentConfig, ConfigTemplate}
  alias Normandy.Behaviours.Config

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
      memory: Normandy.Components.AgentMemory.new_memory(42),
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
end
