defmodule Normandy.Tools.ContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.{AgentMemory, ToolCall}
  alias Normandy.Test.{ContextProbe, FakeTool}
  alias Normandy.Tools.{Context, Executor, Registry}

  defp ctx(values \\ %{memory_namespace: "acme/u-1"}),
    do: %Context{tool_call_id: "c1", values: values}

  describe "Context.build/2" do
    test "takes ids from the config and the call, and values from tool_context" do
      memory = %{AgentMemory.new_memory() | current_turn_id: "turn-1"}

      config = %{
        session_id: "s1",
        name: "agent",
        memory: memory,
        tool_context: %{memory_namespace: "acme/u-1"}
      }

      assert %Context{
               session_id: "s1",
               agent_name: "agent",
               turn_id: "turn-1",
               tool_call_id: "call-9",
               values: %{memory_namespace: "acme/u-1"}
             } = Context.build(config, %ToolCall{id: "call-9", name: "probe", input: %{}})
    end

    test "a partial config gives nil ids and empty values" do
      assert %Context{session_id: nil, agent_name: nil, turn_id: nil, values: %{}} =
               Context.build(%{}, %ToolCall{id: "c", name: "probe", input: %{}})
    end
  end

  describe "Executor with context:" do
    test "a contextual tool gets the context" do
      assert {:ok, ~s(ns="acme/u-1")} =
               Executor.execute_tool(%ContextProbe{notify: self()}, context: ctx())

      assert_receive {:probe_ctx, %Context{tool_call_id: "c1"}}
    end

    test "a contextual tool without context returns its error" do
      assert {{:error,
               "probe requires tool context; it was called outside the dispatch pipeline"},
              :tool_error} = Executor.execute_tool_classified(%ContextProbe{})
    end

    test "a plain tool ignores the context" do
      assert {:ok, "weather in Oslo"} =
               Executor.execute_tool(%FakeTool{city: "Oslo"}, context: ctx())
    end

    test "execute/3 and execute_parallel/3 forward the context" do
      registry = Registry.new([%ContextProbe{notify: self()}])
      assert {:ok, _} = Executor.execute(registry, "probe", context: ctx())
      assert_receive {:probe_ctx, _}

      assert [{:ok, _}] =
               Executor.execute_parallel(registry, [{"p", %ContextProbe{}}], context: ctx())
    end
  end
end
