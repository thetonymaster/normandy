defmodule Normandy.Agents.DispatchTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Dispatch.Pipeline

  describe "default_pipeline/0" do
    test "returns a Pipeline with allow-all policy and no-op budget/hooks" do
      p = Dispatch.default_pipeline()

      assert %Pipeline{} = p
      assert p.before_hooks == []
      assert p.after_hooks == []
      assert p.policy_fn.(%{}, %{}, %{}) == {:allow, %{}}
      assert p.budget_check_fn.(%{}, %{}) == :ok
      assert p.budget_record_fn.(%{}, %{}, %{}) == :ok
    end
  end

  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Tools.Registry

  defmodule FakeTool do
    use Normandy.Schema

    schema do
      field(:city, :string)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.DispatchTest.FakeTool do
    def tool_name(_), do: "weather"
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}
    def run(tool), do: {:ok, "weather in #{tool.city}"}
  end

  defmodule FakeToolWithPrepare do
    use Normandy.Schema

    schema do
      field(:city, :string)
    end

    def prepare_input(tool, input) do
      %{tool | city: String.upcase(input["city"] || "")}
    end
  end

  describe "to_tool_call/1" do
    test "passes a %ToolCall{} through unchanged" do
      call = %ToolCall{id: "c1", name: "weather", input: %{city: "NYC"}}
      assert Dispatch.to_tool_call(call) == call
    end

    test "normalizes a string-keyed JSON map into a %ToolCall{}" do
      raw = %{"id" => "c2", "name" => "weather", "input" => %{"city" => "LA"}}

      assert Dispatch.to_tool_call(raw) ==
               %ToolCall{id: "c2", name: "weather", input: %{"city" => "LA"}}
    end

    test "decodes a JSON-string input and degrades non-map input to %{}" do
      raw = %{"id" => "c3", "name" => "weather", "input" => ~s({"city":"SF"})}
      assert Dispatch.to_tool_call(raw).input == %{"city" => "SF"}

      bad = %{"id" => "c4", "name" => "weather", "input" => [1, 2, 3]}
      assert Dispatch.to_tool_call(bad).input == %{}
    end
  end

  describe "prepare_tool/2" do
    test "maps known string keys onto struct fields and drops unknown keys" do
      prepared = Dispatch.prepare_tool(%FakeTool{}, %{"city" => "NYC", "bogus" => 1})
      assert prepared == %FakeTool{city: "NYC"}
    end

    test "delegates to the tool's prepare_input/2 when exported" do
      prepared = Dispatch.prepare_tool(%FakeToolWithPrepare{}, %{"city" => "nyc"})
      assert prepared == %FakeToolWithPrepare{city: "NYC"}
    end
  end

  defp config_with_tools(tools) do
    %{name: "test-agent", tool_registry: Registry.new(tools)}
  end

  describe "dispatch_one/3 happy path" do
    test "allow → executes the tool and returns a success ToolResult" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}

      result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert %ToolResult{
               tool_call_id: "c1",
               output: "weather in NYC",
               is_error: false
             } = result
    end

    test "accepts a raw string-keyed map (streaming shape)" do
      config = config_with_tools([%FakeTool{}])
      raw = %{"id" => "c9", "name" => "weather", "input" => %{"city" => "LA"}}

      result = Dispatch.dispatch_one(config, raw, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "c9", output: "weather in LA", is_error: false} = result
    end
  end

  describe "dispatch_one/3 registry miss" do
    test "unknown tool → error ToolResult, tool not executed" do
      config = config_with_tools([])
      call = %ToolCall{id: "c5", name: "nope", input: %{}}

      result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert %ToolResult{
               tool_call_id: "c5",
               is_error: true,
               output: %{error: "Tool 'nope' not found in registry"}
             } = result
    end
  end

  describe "dispatch_one/3 policy outcomes" do
    test "deny → error ToolResult with rationale fed into output, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c6", name: "weather", input: %{"city" => "NYC"}}

      deny_policy = fn _config, _call, _tool ->
        {:deny,
         %{reason: "weather tool blocked", rule_id: "R-7", rationale: "shares state with billing"}}
      end

      pipeline = %{Dispatch.default_pipeline() | policy_fn: deny_policy}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert %ToolResult{
               tool_call_id: "c6",
               is_error: true,
               output: %{
                 error: "weather tool blocked",
                 rule_id: "R-7",
                 rationale: "shares state with billing",
                 denied: true,
                 pending_approval: false
               }
             } = result
    end

    test "needs_approval → tagged denial result with pending_approval: true" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c7", name: "weather", input: %{"city" => "NYC"}}

      approval_policy = fn _config, _call, _tool ->
        {:needs_approval, %{reason: "human review", rationale: "high-cost op"}}
      end

      pipeline = %{Dispatch.default_pipeline() | policy_fn: approval_policy}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert %ToolResult{
               tool_call_id: "c7",
               is_error: true,
               output: %{denied: true, pending_approval: true, rationale: "high-cost op"}
             } = result
    end
  end
end
