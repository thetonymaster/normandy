defmodule Normandy.Agents.Turn.DriverTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Driver
  alias Normandy.Agents.Turn.Driver.Handlers

  # A response with no tool calls so a no-tools turn finalizes immediately.
  defp recording_handlers(pid) do
    %Handlers{
      call_llm: fn acc, _state, _req ->
        send(pid, {:call_llm, acc})
        %{content: "hi", tool_calls: []}
      end,
      dispatch_tools: fn _acc, calls -> Enum.map(calls, fn _ -> :result end) end,
      convert: fn _acc, raw, _os -> raw end,
      validate: fn _acc, value -> value end,
      guard: fn _acc, _value -> :ok end,
      append: fn acc, role, _content -> [role | acc] end,
      compact: fn acc, _state, _info -> {acc, %{compacted: false}} end,
      emit: fn _acc, name, _meta -> send(pid, {:emit, name}) end
    }
  end

  test "drive/3 runs a no-tools turn to :stopped, threading acc through append" do
    state = Turn.new(response_model: :rm, output_schema: :rm)
    {acc, final} = Driver.drive(state, recording_handlers(self()), [])

    assert final.status == :stopped
    # The single assistant append threaded "assistant" into the acc list.
    assert acc == ["assistant"]
    assert_received {:call_llm, []}
    assert_received {:emit, :iteration}
  end

  test "drive/3 raises on an unexpected :fail effect" do
    # Feed a state whose next event triggers the FSM's unexpected-event guard.
    state = %Turn.State{status: :tool_dispatch, max_iterations: 5, iterations_left: 5}

    handlers = recording_handlers(self())

    assert_raise RuntimeError, ~r/Turn FSM reached :failed unexpectedly/, fn ->
      # :start on a :tool_dispatch state is unexpected -> {:fail, reason}
      Driver.drive(state, handlers, [])
    end
  end

  test "drive/3 runs a tool loop: dispatches, converts, threads acc across iterations" do
    # Scripted call_llm: first response carries a tool call, second has none.
    {:ok, responses} =
      Agent.start_link(fn ->
        [
          %{content: nil, tool_calls: [%{id: "c1"}]},
          %{content: "final", tool_calls: []}
        ]
      end)

    pid = self()

    handlers = %Handlers{
      call_llm: fn _acc, _state, _req ->
        Agent.get_and_update(responses, fn [h | t] -> {h, t} end)
      end,
      dispatch_tools: fn _acc, calls ->
        send(pid, {:dispatched, length(calls)})
        Enum.map(calls, fn _ -> %{result: :ok} end)
      end,
      convert: fn _acc, raw, output_schema ->
        send(pid, {:convert, output_schema})
        raw
      end,
      validate: fn _acc, value -> value end,
      guard: fn _acc, _value -> :ok end,
      append: fn acc, role, _content -> [role | acc] end,
      compact: fn acc, _state, _info -> {acc, %{compacted: false}} end,
      emit: fn _acc, _name, _meta -> :ok end
    }

    # response_model (:rm) != output_schema (:os) so the convert step fires.
    state = Turn.new(max_iterations: 5, response_model: :rm, output_schema: :os)
    {acc, final} = Driver.drive(state, handlers, [])

    assert final.status == :stopped
    assert_received {:dispatched, 1}
    assert_received {:convert, :os}
    # acc threaded across iterations: assistant (tool turn) -> tool (result) -> assistant (final)
    assert acc == ["assistant", "tool", "assistant"]
  end

  test "drive/3 runs the compact handler at the steering boundary and threads acc" do
    # Drive a real turn from :provisioning (via Turn.new) where:
    # - first LLM response carries a tool call  →  :tool_dispatch → :steering → {:maybe_compact}
    #   → compact handler fires → {:compaction_done} → :assistant_streaming (iteration 2)
    # - second LLM response has no tool calls  →  :finalizing → :stopped
    # This exercises the full steering round-trip through the Driver without
    # bypassing the :start gate.
    pid = self()

    {:ok, responses} =
      Agent.start_link(fn ->
        [
          %{content: nil, tool_calls: [%{id: "c1"}]},
          %{content: "final", tool_calls: []}
        ]
      end)

    handlers = %Handlers{
      call_llm: fn _acc, _s, _r ->
        Agent.get_and_update(responses, fn [h | t] -> {h, t} end)
      end,
      dispatch_tools: fn _acc, calls -> Enum.map(calls, fn _ -> %{ok: true} end) end,
      convert: fn _acc, raw, _os -> raw end,
      validate: fn _acc, v -> v end,
      guard: fn _acc, _v -> :ok end,
      append: fn acc, role, _c -> [role | acc] end,
      compact: fn acc, _s, info ->
        send(pid, {:compacted, info})
        {[:compacted | acc], %{compacted: true}}
      end,
      emit: fn _acc, _n, _m -> :ok end
    }

    state = Turn.new(max_iterations: 5, response_model: :rm, output_schema: :rm)
    {acc, final} = Driver.drive(state, handlers, [])

    assert final.status == :stopped
    # compact handler ran exactly once, between the tool result and the next call
    assert_received {:compacted, %{iterations_left: 4}}
    refute_received {:compacted, _}
    assert :compacted in acc
  end
end
