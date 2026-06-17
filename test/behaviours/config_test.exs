defmodule Normandy.Behaviours.ConfigTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.PolicyEngine
  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Dispatch.Pipeline
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Tools.Registry

  defmodule FakeTool do
    use Normandy.Schema

    schema do
      field(:city, :string)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Behaviours.ConfigTest.FakeTool do
    def tool_name(_), do: "weather"
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}
    def run(tool), do: {:ok, "weather in #{tool.city}"}
  end

  defp config_with_tools(tools) do
    %{name: "test-agent", model: "claude-3-5-sonnet-20241022", tool_registry: Registry.new(tools)}
  end

  describe "default bundle" do
    test "has all-default impl refs" do
      b = %Config{}
      assert b.policy == {PolicyEngine.AllowAll, []}
      assert b.budget == {Normandy.Behaviours.BudgetTracker.NoOp, []}
      assert b.before_hooks == []
      assert b.after_hooks == []
      assert b.credential == {Normandy.Behaviours.CredentialProvider.FromClient, []}
      assert b.model_catalog == {Normandy.Behaviours.ModelCatalog.Static, []}
      assert b.session_store == {Normandy.Behaviours.SessionStore.InMemory, []}
    end

    test "default bundle carries the Native session_registry slot" do
      assert %Normandy.Behaviours.Config{}.session_registry ==
               {Normandy.Behaviours.SessionRegistry.Native, []}
    end

    test "default bundle carries the NoOp compactor slot" do
      b = %Config{}
      assert b.compactor == {Normandy.Behaviours.Compactor.NoOp, []}
    end

    test "to_pipeline/1 ignores session_registry (not a dispatch-path concern)" do
      pipeline = Normandy.Behaviours.Config.to_pipeline(%Normandy.Behaviours.Config{})
      refute Map.has_key?(Map.from_struct(pipeline), :session_registry)
    end
  end

  describe "to_pipeline/1 equivalence with default_pipeline/0" do
    test "default bundle reproduces the chokepoint's default behaviour" do
      p = Config.to_pipeline(%Config{})
      d = Dispatch.default_pipeline()

      assert %Pipeline{} = p
      assert p.before_hooks == d.before_hooks
      assert p.after_hooks == d.after_hooks
      assert p.policy_fn.(%{}, %ToolCall{name: "x"}, %{}) == {:allow, %{}}
      assert p.budget_check_fn.(%{}, %ToolCall{name: "x"}) == :ok
      assert p.budget_record_fn.(%{}, %ToolCall{name: "x"}, %{}) == :ok
    end

    test "nil resolves to the default bundle" do
      assert Config.to_pipeline(nil) == Config.to_pipeline(%Config{})
    end

    test "default bundle executes a tool through dispatch_one/3" do
      pipeline = Config.to_pipeline(%Config{})
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}

      assert %ToolResult{tool_call_id: "c1", output: "weather in NYC", is_error: false} =
               Dispatch.dispatch_one(config, call, pipeline)
    end
  end

  describe "to_pipeline/1 with a non-default bundle" do
    test "a Ruleset policy denies a matching tool through dispatch_one/3" do
      bundle = %Config{
        policy:
          {PolicyEngine.Ruleset,
           rules: [%{match: "weather", action: :deny, rule_id: "R-1", rationale: "blocked"}],
           default_action: :allow}
      }

      pipeline = Config.to_pipeline(bundle)
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c2", name: "weather", input: %{"city" => "NYC"}}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert %ToolResult{
               tool_call_id: "c2",
               is_error: true,
               output: %{denied: true, rule_id: "R-1", rationale: "blocked"}
             } = result
    end

    test "before/after hooks set on the bundle reach the chokepoint" do
      redact = fn _config, _call, %ToolResult{} = r -> %{r | output: "REDACTED"} end
      bundle = %Config{after_hooks: [redact]}

      pipeline = Config.to_pipeline(bundle)
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c3", name: "weather", input: %{"city" => "NYC"}}

      assert %ToolResult{output: "REDACTED"} = Dispatch.dispatch_one(config, call, pipeline)
    end
  end

  describe "BaseAgent integration" do
    test "init/1 stores a supplied behaviours bundle on the config" do
      bundle = %Config{
        policy:
          {PolicyEngine.Ruleset, rules: [%{match: "*", action: :allow}], default_action: :allow}
      }

      config =
        Normandy.Agents.BaseAgent.init(%{
          client: %Normandy.LLM.ClaudioAdapter{api_key: "sk-test"},
          model: "claude-3-5-sonnet-20241022",
          temperature: 0.0,
          behaviours: bundle
        })

      assert config.behaviours == bundle
    end

    test "init/1 defaults behaviours to nil (resolved to defaults at pipeline build)" do
      config =
        Normandy.Agents.BaseAgent.init(%{
          client: %Normandy.LLM.ClaudioAdapter{api_key: "sk-test"},
          model: "claude-3-5-sonnet-20241022",
          temperature: 0.0
        })

      assert config.behaviours == nil
      assert %Pipeline{} = Config.to_pipeline(config.behaviours)
    end
  end
end
