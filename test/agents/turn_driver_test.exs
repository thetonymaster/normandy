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
      dispatch_tools: fn _acc, calls -> Enum.map(calls, fn _ -> :result end) ++ [] end,
      convert: fn _acc, raw, _os -> raw end,
      validate: fn _acc, value -> value end,
      guard: fn _acc, _value -> :ok end,
      append: fn acc, role, _content -> [role | acc] end,
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
end
