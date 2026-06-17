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

  describe "step/2 approval resolution (:awaiting_approval + :approval)" do
    setup do
      pending = [
        %ToolCall{id: "a1", name: "weather", input: %{}},
        %ToolCall{id: "p1", name: "billing", input: %{}}
      ]

      held = [%ToolResult{tool_call_id: "a1", output: "sunny", is_error: false}]
      parked = [%ToolCall{id: "p1", name: "billing", input: %{}}]

      s = %State{
        status: :awaiting_approval,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: pending,
        held_results: held,
        parked_calls: parked
      }

      {:ok, s: s}
    end

    test "all rejected → applies held + denial results in batch order, decrements once", %{s: s} do
      {s2, effects} = Turn.step(s, {:approval, %{"p1" => :reject}})

      assert s2.status == :assistant_streaming
      assert s2.iterations_left == 4
      assert s2.parked_calls == []
      assert s2.held_results == []

      assert [
               {:append_message, "tool", %ToolResult{tool_call_id: "a1", output: "sunny"}},
               {:append_message, "tool",
                %ToolResult{tool_call_id: "p1", is_error: true, output: %{denied: true}}},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},
               {:call_llm, %{response_model: :rm, final: false}}
             ] = effects
    end

    test "absent decision is treated as rejected (fail-closed)", %{s: s} do
      {s2, effects} = Turn.step(s, {:approval, %{}})

      assert s2.status == :assistant_streaming

      assert Enum.any?(
               effects,
               &match?(
                 {:append_message, "tool", %ToolResult{tool_call_id: "p1", is_error: true}},
                 &1
               )
             )
    end

    test "some approved → stays :awaiting_approval, stashes rejected, emits :execute_approved", %{
      s: s
    } do
      {s2, effects} = Turn.step(s, {:approval, %{"p1" => :approve}})

      assert s2.status == :awaiting_approval
      assert s2.parked_calls == []

      assert s2.held_results == [
               %ToolResult{tool_call_id: "a1", output: "sunny", is_error: false}
             ]

      assert effects == [{:execute_approved, [%ToolCall{id: "p1", name: "billing", input: %{}}]}]
    end
  end
end
