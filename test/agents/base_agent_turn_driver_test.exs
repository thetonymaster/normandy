defmodule Normandy.Agents.BaseAgentTurnDriverTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema, BaseAgentOutputSchema, ToolCallResponse}
  alias Normandy.Components.{AgentMemory, ToolCall}
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Registry

  # Re-uses the project-wide ModelMockup: converse/completitions return
  # response_model as-is, giving deterministic LLM responses without network.

  # Fake client for the with-tools characterization tests: a SIMPLIFIED
  # single-use variant of MockToolCallClient (base_agent_tool_loop_test.exs).
  # Omits the tool_call_count guard and true-fallback cond branch because this
  # client is constructed fresh per test and never re-primed — tool_message_count
  # == 0 on the first call is always guaranteed. The dispatch path exercised is
  # the same; only the guard structure is simplified.
  defmodule MockWithToolsClient do
    use Normandy.Schema

    schema do
      field(:final_response, :string, default: "Task completed")
    end

    defimpl Normandy.Agents.Model do
      def completitions(_config, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(
            config,
            _model,
            _temperature,
            _max_tokens,
            messages,
            _response_model,
            _opts \\ []
          ) do
        tool_message_count = Enum.count(messages, fn msg -> msg.role == "tool" end)

        if tool_message_count == 0 do
          %ToolCallResponse{
            content: nil,
            tool_calls: [
              %ToolCall{id: "call_1", name: "calculator", input: %{operation: "add", a: 5, b: 3}}
            ]
          }
        else
          %ToolCallResponse{content: config.final_response, tool_calls: []}
        end
      end
    end
  end

  defp with_tools_agent do
    calc = %Calculator{operation: "add", a: 0, b: 0}
    registry = Registry.new([calc])

    BaseAgent.init(%{
      client: %MockWithToolsClient{},
      model: "test-model",
      temperature: 0.7,
      tool_registry: registry,
      max_tool_iterations: 5
    })
  end

  defp no_tools_agent do
    BaseAgent.init(%{
      client: %NormandyTest.Support.ModelMockup{},
      model: "claude-haiku-4-5-20251001",
      temperature: 0.9
    })
  end

  describe "no-tools run drives through the Turn FSM" do
    test "returns the validated output struct" do
      config = no_tools_agent()
      mock_input = %BaseAgentInputSchema{chat_message: "hello"}

      {_updated, response} = BaseAgent.run(config, mock_input)

      assert %BaseAgentOutputSchema{} = response
    end

    test "appends user + assistant messages to memory in order" do
      config = no_tools_agent()
      mock_input = %BaseAgentInputSchema{chat_message: "hello"}

      {updated, _response} = BaseAgent.run(config, mock_input)

      history = AgentMemory.history(updated.memory)
      roles = Enum.map(history, & &1.role)
      assert roles == ["user", "assistant"]
    end

    test "stores the validated input in config.current_user_input" do
      config = no_tools_agent()
      mock_input = %BaseAgentInputSchema{chat_message: "world"}

      {updated, _response} = BaseAgent.run(config, mock_input)

      assert updated.current_user_input == mock_input
    end

    test "nil input skips user-message admission — only assistant message in history" do
      config = no_tools_agent()

      {updated, response} = BaseAgent.run(config, nil)

      # The admit_turn_input/2 nil branch returns config unchanged, so no
      # "user" message is ever appended. The FSM finalizes by appending one
      # "assistant" message. Starting from an empty memory the only message
      # produced by this call is the assistant reply.
      assert %BaseAgentOutputSchema{} = response

      history = AgentMemory.history(updated.memory)
      roles = Enum.map(history, & &1.role)
      assert roles == ["assistant"]
    end
  end

  describe "with-tools run drives the tool loop through the FSM" do
    test "first response calls a tool, second finalizes; memory has user/assistant/tool/assistant" do
      config = with_tools_agent()
      user_input = %BaseAgentInputSchema{chat_message: "What is 5 + 3?"}

      {updated, response} = BaseAgent.run_with_tools(config, user_input)

      # The final response should be the converted output schema
      assert %BaseAgentOutputSchema{} = response
      assert response.chat_message == "Task completed"

      # Memory should have the full tool-loop sequence in role order
      roles =
        updated.memory
        |> AgentMemory.history()
        |> Enum.map(& &1.role)

      assert roles == ["user", "assistant", "tool", "assistant"]
    end
  end
end
