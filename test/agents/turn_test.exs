defmodule Normandy.Agents.TurnTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.ToolCall

  describe "new/1" do
    test "seeds a provisioning state with iterations_left = max_iterations" do
      s = Turn.new(max_iterations: 3, response_model: :rm, output_schema: :os)

      assert %State{
               status: :provisioning,
               max_iterations: 3,
               iterations_left: 3,
               awaiting_final: false,
               response_model: :rm,
               output_schema: :os,
               pending_calls: []
             } = s
    end

    test "defaults max_iterations to 5" do
      assert Turn.new().max_iterations == 5
      assert Turn.new().iterations_left == 5
    end
  end

  describe "step/2 provisioning" do
    test ":start transitions to :assistant_streaming and emits iteration + call_llm" do
      s = Turn.new(max_iterations: 5, response_model: :rm)

      {s2, effects} = Turn.step(s, :start)

      assert s2.status == :assistant_streaming
      assert s2.iterations_left == 5

      assert effects == [
               {:emit_event, :iteration, %{iteration: 1, iterations_left: 5}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
    end
  end

  describe "step/2 assistant_streaming with no tool calls" do
    test "finalizes: appends assistant message, emits finalize, stops as :completed" do
      s = %State{status: :assistant_streaming, iterations_left: 5, max_iterations: 5}
      resp = %ToolCallResponse{content: "all done", tool_calls: nil}

      {s2, effects} = Turn.step(s, {:llm_response, resp})

      assert s2.status == :stopped
      assert s2.stop_reason == :completed
      assert s2.final_response == resp
      assert s2.last_response == resp

      assert effects == [
               {:append_message, "assistant", resp},
               {:finalize, resp}
             ]
    end

    test "treats an empty tool_calls list as no tool calls" do
      s = %State{status: :assistant_streaming, iterations_left: 5, max_iterations: 5}
      resp = %ToolCallResponse{content: "done", tool_calls: []}

      {s2, _effects} = Turn.step(s, {:llm_response, resp})
      assert s2.status == :stopped
      assert s2.stop_reason == :completed
    end
  end

  describe "step/2 assistant_streaming with tool calls" do
    test "transitions to :tool_dispatch, appends assistant, dispatches the calls" do
      s = %State{status: :assistant_streaming, iterations_left: 5, max_iterations: 5}
      calls = [%ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}]
      resp = %ToolCallResponse{content: nil, tool_calls: calls}

      {s2, effects} = Turn.step(s, {:llm_response, resp})

      assert s2.status == :tool_dispatch
      assert s2.pending_calls == calls
      assert s2.last_response == resp
      refute s2.stop_reason

      assert effects == [
               {:append_message, "assistant", resp},
               {:dispatch_tools, calls}
             ]
    end
  end
end
