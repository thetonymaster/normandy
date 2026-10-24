defmodule Normandy.Tools.ContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.{AgentMemory, ToolCall}
  alias Normandy.Test.{ContextProbe, FakeTool}
  alias Normandy.Tools.{Context, Executor}

  defp ctx(values \\ %{memory_namespace: "acme/u-1"}),
    do: %Context{tool_call_id: "c1", values: values, input: %{}}

  describe "Context.build/3" do
    test "takes ids from the config and the call, values from tool_context, and the input" do
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
               input: %{"q" => 1},
               values: %{memory_namespace: "acme/u-1"}
             } =
               Context.build(config, %ToolCall{id: "call-9", name: "probe", input: %{}}, %{
                 "q" => 1
               })
    end

    test "a partial config gives nil ids and empty values" do
      assert %Context{session_id: nil, agent_name: nil, turn_id: nil, values: %{}} =
               Context.build(%{}, %ToolCall{id: "c", name: "probe", input: %{}}, %{})
    end
  end

  describe "Executor passes the context to run/2" do
    test "the tool receives the context it was given" do
      assert {:ok, ~s(ns="acme/u-1")} =
               Executor.execute_tool(%ContextProbe{notify: self()}, context: ctx())

      assert_receive {:probe_ctx, %Context{tool_call_id: "c1"}}
    end

    test "the input reaches the tool through the context" do
      assert {:ok, "weather in Oslo"} =
               Executor.execute_tool(%FakeTool{}, context: %{ctx() | input: %{"city" => "Oslo"}})
    end
  end
end
