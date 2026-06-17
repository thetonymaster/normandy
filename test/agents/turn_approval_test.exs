defmodule Normandy.Agents.TurnApprovalTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  describe "step/2 park (:tool_dispatch + :needs_approval)" do
    test "moves to :awaiting_approval, holds results + parked calls, emits event + persist" do
      parked = [%ToolCall{id: "p1", name: "billing", input: %{}}]
      held = [%ToolResult{tool_call_id: "a1", output: "ok", is_error: false}]

      s = %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [
          %ToolCall{id: "a1", name: "weather", input: %{}},
          %ToolCall{id: "p1", name: "billing", input: %{}}
        ]
      }

      {s2, effects} = Turn.step(s, {:needs_approval, held, parked})

      assert s2.status == :awaiting_approval
      assert s2.held_results == held
      assert s2.parked_calls == parked
      assert s2.iterations_left == 5

      assert effects == [
               {:emit_event, :awaiting_approval, %{parked: 1}},
               {:persist, s2}
             ]
    end
  end
end
