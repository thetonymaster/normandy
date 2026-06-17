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
               {:persist, s2},
               {:emit_event, :awaiting_approval, %{parked: 1}}
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

      assert s2.status == :steering
      assert s2.iterations_left == 4
      assert s2.parked_calls == []
      assert s2.held_results == []

      assert [
               {:append_message, "tool", %ToolResult{tool_call_id: "a1", output: "sunny"}},
               {:append_message, "tool",
                %ToolResult{tool_call_id: "p1", is_error: true, output: %{denied: true}}},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:maybe_compact, %{iterations_left: 4}}
             ] = effects

      {s3, effects2} = Turn.step(s2, {:compaction_done, %{}})

      assert s3.status == :assistant_streaming

      assert effects2 == [
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
    end

    test "absent decision is treated as rejected (fail-closed)", %{s: s} do
      {s2, effects} = Turn.step(s, {:approval, %{}})

      assert s2.status == :steering

      assert Enum.any?(
               effects,
               &match?(
                 {:append_message, "tool", %ToolResult{tool_call_id: "p1", is_error: true}},
                 &1
               )
             )

      {s3, _effects2} = Turn.step(s2, {:compaction_done, %{}})
      assert s3.status == :assistant_streaming
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

    test "a retried :approval after parked_calls cleared fails, not completes the batch early", %{
      s: s
    } do
      # Approve p1 → parked_calls cleared, still :awaiting_approval, awaiting :approved_results.
      {s2, [{:execute_approved, _}]} = Turn.step(s, {:approval, %{"p1" => :approve}})
      assert s2.status == :awaiting_approval
      assert s2.parked_calls == []

      # A duplicate/retried :approval must NOT re-enter the resolve clause with an
      # empty parked list — that would apply only held_results, drop the approved
      # (still-executing) result, and decrement the batch early. It must fail instead.
      {s3, effects} = Turn.step(s2, {:approval, %{"p1" => :approve}})

      assert s3.status == :failed
      assert {:unexpected_event, :awaiting_approval, _} = s3.error
      assert [{:fail, {:unexpected_event, :awaiting_approval, _}}] = effects
      # Batch not completed: the iteration counter is untouched.
      assert s3.iterations_left == s.iterations_left
    end
  end

  describe "step/2 approved results (:awaiting_approval + :approved_results)" do
    test "merges held + approved results in batch order and applies once" do
      s = %State{
        status: :awaiting_approval,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [
          %ToolCall{id: "a1", name: "weather", input: %{}},
          %ToolCall{id: "p1", name: "billing", input: %{}}
        ],
        held_results: [%ToolResult{tool_call_id: "a1", output: "sunny", is_error: false}],
        parked_calls: []
      }

      approved_results = [%ToolResult{tool_call_id: "p1", output: "charged", is_error: false}]

      {s2, effects} = Turn.step(s, {:approved_results, approved_results})

      assert s2.status == :steering
      assert s2.iterations_left == 4
      assert s2.held_results == []

      assert [
               {:append_message, "tool", %ToolResult{tool_call_id: "a1", output: "sunny"}},
               {:append_message, "tool", %ToolResult{tool_call_id: "p1", output: "charged"}},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:maybe_compact, %{iterations_left: 4}}
             ] = effects

      {s3, effects2} = Turn.step(s2, {:compaction_done, %{}})

      assert s3.status == :assistant_streaming

      assert effects2 == [
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
    end

    test "at the iteration cap, the resolved batch issues the forced-final call" do
      s = %State{
        status: :awaiting_approval,
        iterations_left: 1,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [%ToolCall{id: "p1", name: "billing", input: %{}}],
        held_results: [],
        parked_calls: []
      }

      {s2, effects} =
        Turn.step(
          s,
          {:approved_results, [%ToolResult{tool_call_id: "p1", output: "x", is_error: false}]}
        )

      assert s2.status == :steering
      assert s2.awaiting_final == false
      assert s2.iterations_left == 0

      assert [
               {:append_message, "tool", %ToolResult{tool_call_id: "p1"}},
               {:emit_event, :steering, %{iterations_left: 0}},
               {:maybe_compact, %{iterations_left: 0}}
             ] = effects

      {s3, effects2} = Turn.step(s2, {:compaction_done, %{}})

      assert s3.status == :assistant_streaming
      assert s3.awaiting_final == true

      assert effects2 == [{:call_llm, %{response_model: :os, final: true}}]
    end

    test "mixed approve+reject across a 2-parked batch resolves in batch order" do
      pending = [
        %ToolCall{id: "a1", name: "weather", input: %{}},
        %ToolCall{id: "p1", name: "billing", input: %{}},
        %ToolCall{id: "p2", name: "refund", input: %{}}
      ]

      held = [%ToolResult{tool_call_id: "a1", output: "sunny", is_error: false}]

      parked = [
        %ToolCall{id: "p1", name: "billing", input: %{}},
        %ToolCall{id: "p2", name: "refund", input: %{}}
      ]

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

      # p1 approved, p2 rejected
      {s2, [{:execute_approved, [%ToolCall{id: "p1"}]}]} =
        Turn.step(s, {:approval, %{"p1" => :approve, "p2" => :reject}})

      assert s2.status == :awaiting_approval
      # original a1 result plus the p2 rejection denial are stashed in held_results
      assert s2.held_results |> Enum.map(& &1.tool_call_id) |> Enum.sort() == ["a1", "p2"]

      {s3, effects} =
        Turn.step(
          s2,
          {:approved_results,
           [%ToolResult{tool_call_id: "p1", output: "charged", is_error: false}]}
        )

      assert s3.status == :steering
      assert s3.iterations_left == 4

      appended = for {:append_message, "tool", %ToolResult{tool_call_id: id}} <- effects, do: id
      assert appended == ["a1", "p1", "p2"]

      results = for {:append_message, "tool", r} <- effects, do: r
      p2 = Enum.find(results, &(&1.tool_call_id == "p2"))
      assert p2.is_error == true
      assert p2.output.denied == true

      {s4, _effects2} = Turn.step(s3, {:compaction_done, %{}})
      assert s4.status == :assistant_streaming
    end
  end
end
