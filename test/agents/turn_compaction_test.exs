defmodule Normandy.Agents.TurnCompactionTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  describe "steering boundary" do
    test "a completed tool batch parks in :steering and emits :maybe_compact last" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [%ToolCall{id: "c1", name: "t", input: %{}}]
      }

      results = [%ToolResult{tool_call_id: "c1", output: "ok", is_error: false}]
      {s2, effects} = Turn.step(s, {:tool_results, results})

      assert s2.status == :steering
      assert s2.iterations_left == 4
      assert s2.pending_calls == []
      assert s2.awaiting_final == false

      assert effects == [
               {:append_message, "tool", Enum.at(results, 0)},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:maybe_compact, %{iterations_left: 4}}
             ]
    end

    test "compaction_done below the cap continues with :iteration + next call" do
      s = %State{
        status: :steering,
        iterations_left: 4,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os
      }

      {s2, effects} = Turn.step(s, {:compaction_done, %{compacted: false}})

      assert s2.status == :assistant_streaming
      assert s2.awaiting_final == false

      assert effects == [
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
    end

    test "compaction_done at the cap issues the forced-final call" do
      s = %State{
        status: :steering,
        iterations_left: 0,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os
      }

      {s2, effects} = Turn.step(s, {:compaction_done, %{compacted: true}})

      assert s2.status == :assistant_streaming
      assert s2.awaiting_final == true
      assert effects == [{:call_llm, %{response_model: :os, final: true}}]
    end

    test "compaction_done meta is ignored by the pure core (it already mutated acc in the shell)" do
      s = %State{
        status: :steering,
        iterations_left: 3,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os
      }

      {s_a, eff_a} = Turn.step(s, {:compaction_done, %{compacted: true, tokens_after: 10}})
      {s_b, eff_b} = Turn.step(s, {:compaction_done, %{compacted: false}})
      assert s_a == s_b
      assert eff_a == eff_b
    end
  end
end
