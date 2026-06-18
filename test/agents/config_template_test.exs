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
    # term_to_binary must succeed: no closures, no pids.
    assert is_binary(:erlang.term_to_binary(tmpl))
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
        model_catalog: {Normandy.Behaviours.ModelCatalog.Static, []},
        session_store: {Normandy.Behaviours.SessionStore.InMemory, []},
        session_registry: {Normandy.Behaviours.SessionRegistry.Native, []}
      }
    }

    tr = %Normandy.Tools.Registry{tools: %{"t" => %{}}}
    supp = %{tool_registry: tr, before_hooks: [:bh], after_hooks: [:ah],
             client_builder: fn token -> %{api_key: token, base_url: "https://api"} end}

    config = ConfigTemplate.rebuild(tmpl, supp, "TOKEN")

    assert config.model == "claude-x"
    assert config.tool_registry == tr
    assert config.client.api_key == "TOKEN"
    assert config.behaviours.before_hooks == [:bh]
    assert config.behaviours.policy == {Normandy.Behaviours.PolicyEngine.AllowAll, []}
  end
end
