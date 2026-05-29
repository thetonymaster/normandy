defmodule Normandy.Agents.TurnTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

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

  describe "step/2 tool_dispatch with results (under the cap)" do
    test "appends each tool result, decrements iterations_left, emits steering + iteration, calls LLM" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        pending_calls: [%ToolCall{id: "c1", name: "weather", input: %{}}]
      }

      results = [
        %ToolResult{tool_call_id: "c1", output: "weather in NYC", is_error: false},
        %ToolResult{tool_call_id: "c2", output: "ok", is_error: false}
      ]

      {s2, effects} = Turn.step(s, {:tool_results, results})

      assert s2.status == :assistant_streaming
      assert s2.iterations_left == 4
      assert s2.pending_calls == []
      assert s2.awaiting_final == false

      assert effects == [
               {:append_message, "tool", Enum.at(results, 0)},
               {:append_message, "tool", Enum.at(results, 1)},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
    end
  end

  describe "step/2 iteration cap" do
    test "tool_dispatch results that exhaust the cap issue a forced final call" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 1,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [%ToolCall{id: "c1", name: "weather", input: %{}}]
      }

      results = [%ToolResult{tool_call_id: "c1", output: "x", is_error: false}]

      {s2, effects} = Turn.step(s, {:tool_results, results})

      assert s2.status == :assistant_streaming
      assert s2.awaiting_final == true
      assert s2.iterations_left == 0

      assert effects == [
               {:append_message, "tool", Enum.at(results, 0)},
               {:emit_event, :steering, %{iterations_left: 0}},
               {:call_llm, %{response_model: :os, final: true}}
             ]
    end

    test "the forced final response finalizes regardless of tool calls, as :max_iterations" do
      s = %State{
        status: :assistant_streaming,
        awaiting_final: true,
        iterations_left: 0,
        max_iterations: 5
      }

      # Even if the model tries to call a tool, the forced-final response stops the turn.
      resp = %ToolCallResponse{
        content: "forced answer",
        tool_calls: [%ToolCall{id: "z", name: "noop", input: %{}}]
      }

      {s2, effects} = Turn.step(s, {:llm_response, resp})

      assert s2.status == :stopped
      assert s2.stop_reason == :max_iterations
      assert s2.final_response == resp
      assert s2.awaiting_final == false

      assert effects == [
               {:append_message, "assistant", resp},
               {:finalize, resp}
             ]
    end
  end

  describe "step/2 failures and terminal states" do
    test "llm_error from a non-terminal state transitions to :failed and emits fail" do
      s = %State{status: :assistant_streaming, iterations_left: 3, max_iterations: 5}

      {s2, effects} = Turn.step(s, {:llm_error, :boom})

      assert s2.status == :failed
      assert s2.error == :boom
      assert effects == [{:fail, :boom}]
    end

    test "tool_error from a non-terminal state transitions to :failed and emits fail" do
      s = %State{status: :tool_dispatch, iterations_left: 3, max_iterations: 5}

      {s2, effects} = Turn.step(s, {:tool_error, :crashed})

      assert s2.status == :failed
      assert s2.error == :crashed
      assert effects == [{:fail, :crashed}]
    end

    test ":stopped absorbs any further event with no effects and no status change" do
      s = %State{status: :stopped, stop_reason: :completed, iterations_left: 2, max_iterations: 5}
      assert Turn.step(s, {:llm_response, %ToolCallResponse{}}) == {s, []}
      assert Turn.step(s, {:llm_error, :late}) == {s, []}
    end

    test ":failed absorbs any further event with no effects and no status change" do
      s = %State{status: :failed, error: :prior, iterations_left: 2, max_iterations: 5}
      assert Turn.step(s, {:tool_results, []}) == {s, []}
    end

    test "an unexpected event in a non-terminal state fails loudly with context" do
      s = %State{status: :assistant_streaming, iterations_left: 3, max_iterations: 5}

      {s2, effects} = Turn.step(s, {:tool_results, []})

      assert s2.status == :failed
      assert s2.error == {:unexpected_event, :assistant_streaming, {:tool_results, []}}
      assert effects == [{:fail, {:unexpected_event, :assistant_streaming, {:tool_results, []}}}]
    end
  end
end
