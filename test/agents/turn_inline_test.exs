defmodule Normandy.Agents.Turn.InlineTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Inline
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Dispatch
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Tools.Registry

  defmodule WeatherTool do
    use Normandy.Schema

    schema do
      field(:city, :string)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.Turn.InlineTest.WeatherTool do
    def tool_name(_), do: "weather"
    def tool_description(_), do: "fake weather"
    def input_schema(_), do: %{}
    def run(tool), do: {:ok, "weather in #{tool.city}"}
  end

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

  describe "run/2 with a tool call dispatched through the chokepoint" do
    test "first response calls a tool, second response finalizes; tool actually runs" do
      test_pid = self()
      config = %{name: "t", tool_registry: Registry.new([%WeatherTool{}])}

      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}
      first = %ToolCallResponse{content: nil, tool_calls: [call]}
      second = %ToolCallResponse{content: "the weather is nice", tool_calls: nil}

      # Hand out `first` then `second` on successive LLM calls, tracking count.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      deps = %{
        call_llm: fn _req ->
          n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
          {:ok, if(n == 0, do: first, else: second)}
        end,
        dispatch: fn calls ->
          Enum.map(calls, fn c ->
            Dispatch.dispatch_one(config, c, Dispatch.default_pipeline())
          end)
        end,
        append: fn role, content -> send(test_pid, {:appended, role, content}) end,
        emit: fn _name, _meta -> :ok end
      }

      state = Turn.new(max_iterations: 5, response_model: :rm)
      assert {:ok, final} = Inline.run(state, deps)

      assert final.status == :stopped
      assert final.stop_reason == :completed
      assert final.final_response == second

      # The assistant tool-call response, the real tool result, then the final
      # assistant response were appended, in order.
      assert_received {:appended, "assistant", ^first}

      assert_received {:appended, "tool",
                       %ToolResult{tool_call_id: "c1", output: "weather in NYC", is_error: false}}

      assert_received {:appended, "assistant", ^second}
    end
  end
end
