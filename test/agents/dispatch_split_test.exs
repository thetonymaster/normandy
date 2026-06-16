defmodule Normandy.Agents.DispatchSplitTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Dispatch
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Tools.Registry

  defmodule FakeTool do
    use Normandy.Schema

    schema do
      field(:city, :string)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.DispatchSplitTest.FakeTool do
    def tool_name(_), do: "weather"
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}
    def run(tool), do: {:ok, "weather in #{tool.city}"}
  end

  defp config_with_tools(tools) do
    %{name: "test-agent", tool_registry: Registry.new(tools)}
  end

  describe "classify/3" do
    test "allow → {:execute, prepared_tool, normalized_call}" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}

      assert {:execute, %FakeTool{city: "NYC"}, %ToolCall{id: "c1"}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "deny → {:deny, error ToolResult}, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c2", name: "weather", input: %{"city" => "NYC"}}

      deny = fn _c, _call, _tool -> {:deny, %{reason: "blocked", rule_id: "R-1"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: deny}

      assert {:deny, %ToolResult{tool_call_id: "c2", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "needs_approval → {:needs_approval, prepared, call, info}" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c3", name: "weather", input: %{"city" => "NYC"}}

      approve = fn _c, _call, _tool -> {:needs_approval, %{rationale: "high-cost"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: approve}

      assert {:needs_approval, %FakeTool{}, %ToolCall{id: "c3"}, %{rationale: "high-cost"}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "registry miss → {:deny, not-found ToolResult}" do
      config = config_with_tools([])
      call = %ToolCall{id: "c4", name: "nope", input: %{}}

      assert {:deny, %ToolResult{tool_call_id: "c4", is_error: true}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "before-hook {:halt, result} → {:deny, result}, policy not consulted" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c5", name: "weather", input: %{"city" => "NYC"}}

      halt = fn _c, %ToolCall{id: id} ->
        {:halt, %ToolResult{tool_call_id: id, output: %{error: "hooked"}, is_error: true}}
      end

      pipeline = %{Dispatch.default_pipeline() | before_hooks: [halt]}

      assert {:deny, %ToolResult{tool_call_id: "c5", output: %{error: "hooked"}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "accepts a raw string-keyed map" do
      config = config_with_tools([%FakeTool{}])
      raw = %{"id" => "c6", "name" => "weather", "input" => %{"city" => "LA"}}

      assert {:execute, %FakeTool{city: "LA"}, %ToolCall{id: "c6"}} =
               Dispatch.classify(config, raw, Dispatch.default_pipeline())
    end
  end

  describe "execute/4" do
    test "runs the tool and returns a success ToolResult" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c7", name: "weather", input: %{"city" => "NYC"}}
      {:execute, prepared, call} = Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "c7", output: "weather in NYC", is_error: false} =
               Dispatch.execute(config, prepared, call, Dispatch.default_pipeline())
    end

    test "budget {:error, reason} → budget-denial result, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c8", name: "weather", input: %{"city" => "NYC"}}
      {:execute, prepared, call} = Dispatch.classify(config, call, Dispatch.default_pipeline())

      over = fn _c, _call -> {:error, :cap} end
      pipeline = %{Dispatch.default_pipeline() | budget_check_fn: over}

      result = Dispatch.execute(config, prepared, call, pipeline)
      assert %ToolResult{tool_call_id: "c8", is_error: true, output: %{denied: true}} = result
      assert result.output.error =~ "budget check failed"
    end
  end

  describe "dispatch_one/3 == classify ➞ execute" do
    test "allow path equals execute of the classified call" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c9", name: "weather", input: %{"city" => "NYC"}}
      p = Dispatch.default_pipeline()

      {:execute, prepared, call2} = Dispatch.classify(config, call, p)

      assert Dispatch.dispatch_one(config, call, p) ==
               Dispatch.execute(config, prepared, call2, p)
    end

    test "needs_approval still collapses to the interim denial (pending_approval: true)" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c10", name: "weather", input: %{"city" => "NYC"}}
      approve = fn _c, _call, _tool -> {:needs_approval, %{rationale: "r"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: approve}

      assert %ToolResult{is_error: true, output: %{pending_approval: true, denied: true}} =
               Dispatch.dispatch_one(config, call, pipeline)
    end
  end
end
