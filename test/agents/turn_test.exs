defmodule Normandy.Agents.TurnTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Components.Message
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.LLMError

  @cap_notice "You have used all available tool calls for this turn. Answer now with what you " <>
                "have, and say what you could not finish."

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

    test "defaults max_iterations to 20" do
      assert Turn.new().max_iterations == 20
      assert Turn.new().iterations_left == 20
      assert %State{}.max_iterations == 20
    end

    test "rejects max_iterations below 1, mirroring the pos_integer() contract" do
      assert_raise ArgumentError,
                   ~r/^Normandy\.Agents\.Turn\.new\/1: invalid value for :max_iterations option: expected positive integer, got: 0/,
                   fn ->
                     Turn.new(max_iterations: 0)
                   end

      assert_raise ArgumentError, ~r/got: -1/, fn ->
        Turn.new(max_iterations: -1)
      end
    end

    test "rejects a non-integer max_iterations" do
      assert_raise ArgumentError, ~r/got: 1.5/, fn ->
        Turn.new(max_iterations: 1.5)
      end

      assert_raise ArgumentError, ~r/got: "5"/, fn ->
        Turn.new(max_iterations: "5")
      end
    end
  end

  describe "step/2 provisioning" do
    test ":start parks in :steering and asks to compact before the first LLM call" do
      s = Turn.new(max_iterations: 5, response_model: :rm)

      {s2, effects} = Turn.step(s, :start)

      assert s2.status == :steering
      assert s2.iterations_left == 5
      assert effects == [{:maybe_compact, %{iterations_left: 5, mid_round: false}}]
    end

    test "compaction_done after :start emits iteration 1 + the first call_llm" do
      {s2, _} = Turn.step(Turn.new(max_iterations: 5, response_model: :rm), :start)

      {s3, effects} = Turn.step(s2, {:compaction_done, %{compacted: false}})

      assert s3.status == :assistant_streaming

      assert effects == [
               {:emit_event, :iteration, %{iteration: 1, iterations_left: 5, final: false}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
    end
  end

  describe "step/2 assistant_streaming with no tool calls (enters :finalizing)" do
    test "enters :finalizing as :completed and emits :convert_output when response_model != output_schema" do
      s = %State{
        status: :assistant_streaming,
        iterations_left: 5,
        max_iterations: 5,
        response_model: %ToolCallResponse{},
        output_schema: :os
      }

      resp = %ToolCallResponse{content: "all done", tool_calls: nil}

      {s2, effects} = Turn.step(s, {:llm_response, resp})

      assert s2.status == :finalizing
      assert s2.stop_reason == :completed
      assert s2.last_response == resp
      refute s2.final_response

      assert effects == [{:convert_output, resp, :os}]
    end

    test "enters :finalizing and emits :validate_output (skips convert) when response_model == output_schema" do
      s = %State{
        status: :assistant_streaming,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :os,
        output_schema: :os
      }

      resp = %ToolCallResponse{content: "done", tool_calls: []}

      {s2, effects} = Turn.step(s, {:llm_response, resp})

      assert s2.status == :finalizing
      assert s2.stop_reason == :completed
      assert effects == [{:validate_output, resp}]
    end
  end

  describe "step/2 finalizing pipeline" do
    test ":output_converted advances to :validate_output" do
      s = %State{
        status: :finalizing,
        stop_reason: :completed,
        iterations_left: 4,
        max_iterations: 5
      }

      {s2, effects} = Turn.step(s, {:output_converted, :converted})

      assert s2.status == :finalizing
      assert effects == [{:validate_output, :converted}]
    end

    test ":output_validated advances to :guard_output" do
      s = %State{
        status: :finalizing,
        stop_reason: :completed,
        iterations_left: 4,
        max_iterations: 5
      }

      {s2, effects} = Turn.step(s, {:output_validated, :validated})

      assert s2.status == :finalizing
      assert effects == [{:guard_output, :validated}]
    end

    test ":output_guarded finalizes: stops, sets final_response, appends assistant, emits finalize" do
      s = %State{
        status: :finalizing,
        stop_reason: :completed,
        iterations_left: 4,
        max_iterations: 5
      }

      {s2, effects} = Turn.step(s, {:output_guarded, :final_value})

      assert s2.status == :stopped
      assert s2.stop_reason == :completed
      assert s2.final_response == :final_value

      assert effects == [
               {:append_message, "assistant", :final_value},
               {:finalize, :final_value}
             ]
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

      assert s2.status == :steering
      assert s2.iterations_left == 4
      assert s2.pending_calls == []
      assert s2.awaiting_final == false

      assert effects == [
               {:append_message, "tool", Enum.at(results, 0)},
               {:append_message, "tool", Enum.at(results, 1)},
               {:persist, s2},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:maybe_compact, %{iterations_left: 4, mid_round: true}}
             ]

      {s3, effects2} = Turn.step(s2, {:compaction_done, %{}})

      assert s3.status == :assistant_streaming

      assert effects2 == [
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4, final: false}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
    end
  end

  describe "step/2 batch completeness (July LOW)" do
    defp batch_state(calls) do
      %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        pending_calls: calls
      }
    end

    defp batch_call(id), do: %ToolCall{id: id, name: "weather", input: %{}}
    defp batch_result(id), do: %ToolResult{tool_call_id: id, output: "ok", is_error: false}

    test "a batch whose results leave a call unanswered fails the turn before the next LLM call" do
      s = batch_state([batch_call("c1"), batch_call("c2"), batch_call("c3")])
      results = [batch_result("c1"), batch_result("c3")]

      {s2, effects} = Turn.step(s, {:tool_results, results})

      reason = {:unexpected_event, :tool_dispatch, {:incomplete_batch, ["c2"]}}
      assert s2.status == :failed
      assert s2.error == reason
      assert s2.pending_calls == []

      assert effects == [
               {:append_message, "tool", batch_result("c1")},
               {:append_message, "tool", batch_result("c3")},
               {:fail, reason}
             ]
    end

    test "an approval that resolves a batch short fails it the same way" do
      parked = %State{
        status: :awaiting_approval,
        iterations_left: 5,
        max_iterations: 5,
        pending_calls: [batch_call("c1"), batch_call("c2")],
        parked_calls: [batch_call("c2")],
        held_results: [batch_result("c1")]
      }

      # Complete: c1 held, c2 rejected.
      {s2, effects} = Turn.step(parked, {:approval, %{"c2" => :reject}})
      assert s2.status == :steering
      refute Enum.any?(effects, &match?({:fail, _}, &1))

      # Short: the approved c2 came back with no result.
      {running, [{:execute_approved, [_c2]}]} =
        Turn.step(parked, {:approval, %{"c2" => :approve}})

      {s3, effects3} = Turn.step(running, {:approved_results, []})

      assert s3.error == {:unexpected_event, :awaiting_approval, {:incomplete_batch, ["c2"]}}
      assert effects3 == [{:append_message, "tool", batch_result("c1")}, {:fail, s3.error}]
    end

    test "a complete batch, in any order, and an empty continuation pass" do
      {s2, _} =
        Turn.step(
          batch_state([batch_call("c1"), batch_call("c2")]),
          {:tool_results, [batch_result("c2"), batch_result("c1")]}
        )

      assert s2.status == :steering

      {s3, _} = Turn.step(batch_state([]), {:tool_results, []})
      assert s3.status == :steering
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

      assert s2.status == :steering
      assert s2.awaiting_final == false
      assert s2.iterations_left == 0

      # The notice follows the batch's results and is persisted with them, before
      # the steering state: a resumed turn does not append it twice.
      assert effects == [
               {:append_message, "tool", Enum.at(results, 0)},
               {:append_message, "user", @cap_notice},
               {:persist, s2},
               {:emit_event, :steering, %{iterations_left: 0}},
               {:maybe_compact, %{iterations_left: 0, mid_round: true}}
             ]

      {s3, effects2} = Turn.step(s2, {:compaction_done, %{}})

      assert s3.status == :assistant_streaming
      assert s3.awaiting_final == true

      assert effects2 == [
               {:emit_event, :iteration, %{iteration: 6, iterations_left: 0, final: true}},
               {:call_llm, %{response_model: :rm, final: true}}
             ]
    end

    test "the forced final response enters :finalizing as :max_iterations and is converted" do
      s = %State{
        status: :assistant_streaming,
        awaiting_final: true,
        iterations_left: 0,
        max_iterations: 5,
        response_model: %ToolCallResponse{},
        output_schema: :os
      }

      # The final call ran under tool_choice :none, so tool calls here are ignored: the
      # answer is converted from its text like any final answer.
      resp = %ToolCallResponse{
        content: "forced answer",
        tool_calls: [%ToolCall{id: "z", name: "noop", input: %{}}]
      }

      {s2, effects} = Turn.step(s, {:llm_response, resp})

      assert s2.status == :finalizing
      assert s2.stop_reason == :max_iterations
      assert s2.awaiting_final == false
      assert s2.last_response == resp

      assert effects == [{:convert_output, resp, :os}]
    end

    test "a cap-hitting batch is the only one that appends the notice" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 2,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [%ToolCall{id: "c1", name: "weather", input: %{}}]
      }

      results = [%ToolResult{tool_call_id: "c1", output: "x", is_error: false}]
      {_s2, effects} = Turn.step(s, {:tool_results, results})

      refute Enum.any?(effects, &match?({:append_message, "user", _}, &1))
    end

    test "an empty batch at the cap appends no notice" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 1,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: []
      }

      {s2, effects} = Turn.step(s, {:tool_results, []})

      assert s2.iterations_left == 0

      assert effects == [
               {:persist, s2},
               {:emit_event, :steering, %{iterations_left: 0}},
               {:maybe_compact, %{iterations_left: 0, mid_round: true}}
             ]
    end

    test "a paused final call is continued as the final call, with no user message" do
      s = %State{
        status: :assistant_streaming,
        awaiting_final: true,
        iterations_left: 0,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os
      }

      paused = %{content: "Searching.", tool_calls: [], stop_reason: :pause_turn}
      {s2, effects} = Turn.step(s, {:llm_response, paused})

      # final_pauses counts the continuation; iterations_left stays at 0.
      assert s2.status == :steering
      assert s2.awaiting_final == false
      assert s2.final_pauses == 1
      assert s2.iterations_left == 0

      assert effects == [
               {:append_message, "assistant", paused},
               {:persist, s2},
               {:emit_event, :steering, %{iterations_left: 0}},
               {:maybe_compact, %{iterations_left: 0, mid_round: true}}
             ]

      {s3, effects2} = Turn.step(s2, {:compaction_done, %{}})

      assert s3.awaiting_final == true

      assert effects2 == [
               {:emit_event, :iteration, %{iteration: 6, iterations_left: 0, final: true}},
               {:call_llm, %{response_model: :rm, final: true}}
             ]
    end

    test "a final call still paused after 3 continuations fails the turn with :pause_turn" do
      usage = %{input_tokens: 10, output_tokens: 2}

      paused = %{
        content: "Searching.",
        tool_calls: [],
        stop_reason: :pause_turn,
        usage: usage
      }

      s = %State{
        status: :assistant_streaming,
        awaiting_final: true,
        iterations_left: 0,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os
      }

      {s, effects, continuations} =
        Enum.reduce_while(1..10, {s, [], 0}, fn _, {s, _effects, n} ->
          case Turn.step(s, {:llm_response, paused}) do
            {%State{status: :steering} = s2, _} ->
              {s3, _} = Turn.step(s2, {:compaction_done, %{}})
              {:cont, {s3, [], n + 1}}

            {s2, effects} ->
              {:halt, {s2, effects, n}}
          end
        end)

      assert continuations == 3
      assert s.status == :failed
      assert s.final_pauses == 3
      assert s.iterations_left == 0
      assert [{:fail, %LLMError{} = error}] = effects
      assert s.error == error

      # No model text in the error; the response's usage is kept.
      assert %LLMError{
               type: :pause_turn,
               retryable?: false,
               reason: {:stop_reason, :pause_turn},
               usage: ^usage
             } = error

      refute error.message =~ "Searching."
    end

    test "a paused final call with tool calls is not continued" do
      s = %State{
        status: :assistant_streaming,
        awaiting_final: true,
        iterations_left: 0,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os
      }

      paused = %{
        content: nil,
        tool_calls: [%ToolCall{id: "z", name: "noop", input: %{}}],
        stop_reason: :pause_turn
      }

      assert {%State{status: :finalizing}, [{:convert_output, ^paused, :os}]} =
               Turn.step(s, {:llm_response, paused})
    end
  end

  describe "step/2 persist at the steering boundary" do
    test "a completed tool batch persists the steering state before compaction" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 3,
        max_iterations: 5,
        pending_calls: []
      }

      {s2, effects} = Turn.step(s, {:tool_results, []})

      assert s2.status == :steering

      assert Enum.any?(
               effects,
               &match?({:persist, %State{status: :steering}}, &1)
             )

      # persist comes before maybe_compact
      persist_idx = Enum.find_index(effects, &match?({:persist, _}, &1))
      compact_idx = Enum.find_index(effects, &match?({:maybe_compact, _}, &1))
      assert persist_idx < compact_idx
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

    test "an unexpected event in :finalizing fails loudly with context" do
      s = %State{
        status: :finalizing,
        stop_reason: :completed,
        iterations_left: 2,
        max_iterations: 5
      }

      {s2, effects} = Turn.step(s, {:llm_response, %ToolCallResponse{}})

      assert s2.status == :failed
      assert s2.error == {:unexpected_event, :finalizing, {:llm_response, %ToolCallResponse{}}}

      assert effects == [
               {:fail, {:unexpected_event, :finalizing, {:llm_response, %ToolCallResponse{}}}}
             ]
    end
  end

  describe "unanswered_tool_calls/1" do
    defp call(id), do: %ToolCall{id: id, name: "tool_#{id}", input: %{}}

    defp assistant_msg(calls),
      do: %Message{role: "assistant", content: %{content: "", tool_calls: calls}}

    defp tool_msg(id),
      do: %Message{role: "tool", content: %ToolResult{tool_call_id: id, output: "x"}}

    defp user_msg(text), do: %Message{role: "user", content: text}

    test "an empty history has none" do
      assert Turn.unanswered_tool_calls([]) == []
    end

    test "a latest assistant message without tool calls has none" do
      assert Turn.unanswered_tool_calls([
               user_msg("hi"),
               %Message{role: "assistant", content: "hello"}
             ]) == []

      assert Turn.unanswered_tool_calls([user_msg("hi"), assistant_msg(nil)]) == []
    end

    test "a fully answered batch has none" do
      messages = [
        user_msg("go"),
        assistant_msg([call("a"), call("b")]),
        tool_msg("b"),
        tool_msg("a")
      ]

      assert Turn.unanswered_tool_calls(messages) == []
    end

    test "an unanswered batch returns every call in tool_use order" do
      messages = [user_msg("go"), assistant_msg([call("a"), call("b")])]
      assert Turn.unanswered_tool_calls(messages) == [call("a"), call("b")]
    end

    test "a partly answered batch returns the missing calls" do
      messages = [user_msg("go"), assistant_msg([call("a"), call("b")]), tool_msg("a")]
      assert Turn.unanswered_tool_calls(messages) == [call("b")]
    end

    test "results for an earlier batch do not answer the latest one" do
      messages = [
        user_msg("go"),
        assistant_msg([call("a")]),
        tool_msg("a"),
        assistant_msg([call("b")])
      ]

      assert Turn.unanswered_tool_calls(messages) == [call("b")]
    end
  end

  describe "paused_last?/1" do
    @user %Message{role: "user", content: "q1"}

    for reason <- [:pause_turn, "pause_turn"] do
      test "is true when the last message is a paused assistant turn (#{inspect(reason)})" do
        paused = %ToolCallResponse{tool_calls: [], stop_reason: unquote(reason)}
        assert Turn.paused_last?([@user, %Message{role: "assistant", content: paused}])
      end
    end

    test "is false for an answer, a tool call, a tool result, a user message or nothing" do
      paused = %Message{
        role: "assistant",
        content: %ToolCallResponse{tool_calls: [], stop_reason: :pause_turn}
      }

      answer = %Message{role: "assistant", content: %ToolCallResponse{content: "done"}}

      tool_use = %Message{
        role: "assistant",
        content: %ToolCallResponse{tool_calls: [call("a")], stop_reason: :pause_turn}
      }

      result = %Message{role: "tool", content: %ToolResult{tool_call_id: "a", output: "ok"}}

      refute Turn.paused_last?([])
      refute Turn.paused_last?([@user])
      refute Turn.paused_last?([@user, answer])
      refute Turn.paused_last?([@user, %Message{role: "assistant", content: "done"}])
      refute Turn.paused_last?([@user, tool_use])
      refute Turn.paused_last?([@user, tool_use, result])
      refute Turn.paused_last?([@user, paused, @user])
    end
  end
end
