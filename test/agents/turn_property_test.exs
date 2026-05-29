defmodule Normandy.Agents.TurnPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  @statuses [
    :provisioning,
    :assistant_streaming,
    :tool_dispatch,
    :awaiting_approval,
    :steering,
    :stopped,
    :failed
  ]

  defp event_gen do
    one_of([
      constant(:start),
      constant({:llm_response, %ToolCallResponse{content: "x", tool_calls: nil}}),
      constant(
        {:llm_response,
         %ToolCallResponse{content: nil, tool_calls: [%ToolCall{id: "c", name: "t", input: %{}}]}}
      ),
      constant({:tool_results, [%ToolResult{tool_call_id: "c", output: "o", is_error: false}]}),
      constant({:llm_error, :boom}),
      constant({:tool_error, :crash}),
      constant({:bogus_event, 1})
    ])
  end

  property "step/2 always returns a State with a known status and never raises" do
    check all(
            max <- integer(1..6),
            left <- integer(0..6),
            status <- member_of(@statuses),
            event <- event_gen()
          ) do
      s = %State{status: status, max_iterations: max, iterations_left: left}
      {s2, effects} = Turn.step(s, event)

      assert %State{} = s2
      assert s2.status in @statuses
      assert is_list(effects)
    end
  end

  property "step/2 never increases iterations_left" do
    check all(
            max <- integer(1..6),
            left <- integer(0..6),
            status <- member_of(@statuses),
            event <- event_gen()
          ) do
      s = %State{status: status, max_iterations: max, iterations_left: left}
      {s2, _effects} = Turn.step(s, event)
      assert s2.iterations_left <= left
    end
  end

  property "terminal states are absorbing: no status change and no effects" do
    check all(
            status <- member_of([:stopped, :failed]),
            event <- event_gen()
          ) do
      s = %State{status: status, max_iterations: 5, iterations_left: 2}
      assert {^s, []} = Turn.step(s, event)
    end
  end

  property "a full inline-style run stops within max_iterations + 1 LLM calls" do
    # Simulate the always-tool worst case purely over step/2 (no interpreter):
    # count how many {:call_llm, _} effects are produced before reaching :stopped.
    # The cap allows `max` tool-dispatching calls plus exactly one forced final
    # call, so the worst case is `max + 1` total LLM calls.
    check all(max <- integer(1..5)) do
      tool_resp = %ToolCallResponse{
        content: nil,
        tool_calls: [%ToolCall{id: "c", name: "t", input: %{}}]
      }

      results = [%ToolResult{tool_call_id: "c", output: "o", is_error: false}]

      {calls, status} =
        drive(
          Turn.new(max_iterations: max, response_model: :rm, output_schema: :os),
          tool_resp,
          results,
          0
        )

      assert status == :stopped
      assert calls <= max + 1
    end
  end

  # Helper: feed events the way the interpreter would, counting :call_llm effects,
  # always answering an LLM call with a tool-call response (worst case).
  defp drive(state, tool_resp, results, calls) do
    {state, effects} = Turn.step(state, next_event(state, tool_resp, results))
    calls = calls + Enum.count(effects, &match?({:call_llm, _}, &1))

    case state.status do
      s when s in [:stopped, :failed] -> {calls, s}
      _ -> drive(state, tool_resp, results, calls)
    end
  end

  defp next_event(%State{status: :provisioning}, _tr, _res), do: :start

  defp next_event(%State{status: :assistant_streaming}, tool_resp, _res),
    do: {:llm_response, tool_resp}

  defp next_event(%State{status: :tool_dispatch}, _tr, results), do: {:tool_results, results}
end
