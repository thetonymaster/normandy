defmodule Normandy.Agents.Turn.InlineTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Inline
  alias Normandy.Agents.ToolCallResponse

  describe "run/2 with no tool calls" do
    test "calls the LLM once, finalizes, returns {:ok, stopped-state}" do
      test_pid = self()

      resp = %ToolCallResponse{content: "hello", tool_calls: nil}

      deps = %{
        call_llm: fn req ->
          send(test_pid, {:called_llm, req})
          {:ok, resp}
        end,
        dispatch: fn _calls -> flunk("dispatch should not be called with no tool calls") end,
        append: fn role, content -> send(test_pid, {:appended, role, content}) end,
        emit: fn name, meta -> send(test_pid, {:emitted, name, meta}) end
      }

      state = Turn.new(max_iterations: 5, response_model: :rm)
      assert {:ok, final} = Inline.run(state, deps)

      assert final.status == :stopped
      assert final.stop_reason == :completed
      assert final.final_response == resp

      assert_received {:emitted, :iteration, %{iteration: 1}}
      assert_received {:called_llm, %{response_model: :rm, final: false}}
      assert_received {:appended, "assistant", ^resp}
    end
  end
end
