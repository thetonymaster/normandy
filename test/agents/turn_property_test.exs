defmodule Normandy.Agents.TurnPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  @statuses [
    :provisioning,
    :assistant_streaming,
    :tool_dispatch,
    :finalizing,
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
      constant({:output_converted, :c}),
      constant({:output_validated, :v}),
      constant({:output_guarded, :g}),
      constant({:llm_error, :boom}),
      constant({:tool_error, :crash}),
      constant(
        {:needs_approval, [%ToolResult{tool_call_id: "a", output: "o", is_error: false}],
         [%ToolCall{id: "p", name: "t", input: %{}}]}
      ),
      constant({:approval, %{"p" => :approve}}),
      constant({:approval, %{"p" => :reject}}),
      constant(
        {:approved_results, [%ToolResult{tool_call_id: "p", output: "o", is_error: false}]}
      ),
      constant({:compaction_done, %{}}),
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

  # The shells perform the leading effects in order and act on the last one: every effect
  # that waits for an event (or ends the turn) comes last, and there is at most one.
  @in_order [:emit_event, :append_message, :persist]

  property "step/2 puts at most one effect that waits for an event, and puts it last" do
    check all(
            max <- integer(1..6),
            left <- integer(0..6),
            status <- member_of(@statuses),
            event <- event_gen()
          ) do
      s = %State{status: status, max_iterations: max, iterations_left: left}
      {_s2, effects} = Turn.step(s, event)

      waiting = Enum.reject(effects, &(elem(&1, 0) in @in_order))
      assert length(waiting) <= 1

      if waiting != [] do
        assert List.last(effects) == hd(waiting)
      end
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

  property "park → approve → approved-results decrements once and preserves batch order" do
    check all(left <- integer(2..6)) do
      pending = [
        %ToolCall{id: "a1", name: "weather", input: %{}},
        %ToolCall{id: "p1", name: "billing", input: %{}}
      ]

      held = [%ToolResult{tool_call_id: "a1", output: "sunny", is_error: false}]
      parked = [%ToolCall{id: "p1", name: "billing", input: %{}}]

      s0 = %State{
        status: :tool_dispatch,
        iterations_left: left,
        max_iterations: 6,
        response_model: :rm,
        output_schema: :os,
        pending_calls: pending
      }

      {s1, _} = Turn.step(s0, {:needs_approval, held, parked})
      assert s1.status == :awaiting_approval

      {s2, _} = Turn.step(s1, {:approval, %{"p1" => :approve}})
      assert s2.status == :awaiting_approval

      {s3, effects} =
        Turn.step(
          s2,
          {:approved_results, [%ToolResult{tool_call_id: "p1", output: "ok", is_error: false}]}
        )

      # exactly one decrement across the whole parked batch
      assert s3.iterations_left == left - 1

      # tool appends are in pending_calls order: a1 then p1
      appended = for {:append_message, "tool", %ToolResult{tool_call_id: id}} <- effects, do: id
      assert appended == ["a1", "p1"]
    end
  end

  # Helper: feed events the way an interpreter would, counting :call_llm effects,
  # always answering an LLM call with a tool-call response (worst case). When the
  # turn reaches :finalizing, walk the convert->validate->guard pipeline to a stop
  # using identity transforms (feed the response straight back at each stage).
  defp drive(state, tool_resp, results, calls) do
    case state.status do
      :finalizing ->
        # Both finalize entries (convert-path and validate-path) accept
        # {:output_converted,_} first: the convert clause emits :validate_output,
        # and on the validate-path the {:output_converted,_} clause simply emits
        # :validate_output as well. Then {:output_validated,_} -> {:guard_output},
        # and {:output_guarded,_} -> :stopped. Deterministic, no new :call_llm.
        {s1, _} = Turn.step(state, {:output_converted, state.last_response})
        {s2, _} = Turn.step(s1, {:output_validated, state.last_response})
        {s3, _} = Turn.step(s2, {:output_guarded, state.last_response})
        {calls, s3.status}

      status when status in [:stopped, :failed] ->
        {calls, status}

      _ ->
        {state, effects} = Turn.step(state, next_event(state, tool_resp, results))
        calls = calls + Enum.count(effects, &match?({:call_llm, _}, &1))
        drive(state, tool_resp, results, calls)
    end
  end

  defp next_event(%State{status: :provisioning}, _tr, _res), do: :start

  defp next_event(%State{status: :assistant_streaming}, tool_resp, _res),
    do: {:llm_response, tool_resp}

  defp next_event(%State{status: :tool_dispatch}, _tr, results), do: {:tool_results, results}

  defp next_event(%State{status: :steering}, _tr, _res), do: {:compaction_done, %{}}

  property "tokens_compacted only grows and equals the sum of positive integer tokens_removed on compacted metas" do
    removed_gen = one_of([integer(-1_000..100_000), constant(nil), float()])

    meta_gen =
      one_of([
        map({boolean(), removed_gen}, fn {c, n} -> %{compacted: c, tokens_removed: n} end),
        map(integer(0..1_000), fn n -> %{compacted: true, tokens_before: n, tokens_after: 0} end),
        constant(%{compacted: false}),
        constant(%{})
      ])

    check all(metas <- list_of(meta_gen)) do
      start = %State{status: :steering, iterations_left: 10_000, max_iterations: 10_000}

      final =
        Enum.reduce(metas, start, fn meta, s ->
          {s2, _} = Turn.step(%{s | status: :steering}, {:compaction_done, meta})
          assert s2.tokens_compacted >= s.tokens_compacted
          s2
        end)

      # Oracle written from the contract, not from add_compacted/2.
      expected =
        for %{compacted: true, tokens_removed: n} <- metas, is_integer(n), n > 0, reduce: 0 do
          acc -> acc + n
        end

      assert final.tokens_compacted == expected
    end
  end
end
