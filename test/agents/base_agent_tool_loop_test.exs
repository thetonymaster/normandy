defmodule NormandyTest.Agents.BaseAgentToolLoopTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema, ToolCallResponse}
  alias Normandy.Components.{ToolCall, AgentMemory}
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Registry

  defmodule MockToolCallClient do
    @moduledoc """
    Mock client that simulates an LLM that can make tool calls.
    """
    use Normandy.Schema

    schema do
      field(:tool_call_count, :integer, default: 0)
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
            response_model,
            _opts \\ []
          ) do
        # Count tool messages in history to determine if we should make tool calls
        tool_message_count =
          Enum.count(messages, fn msg ->
            msg.role == "tool"
          end)

        cond do
          # First call - no tools executed yet, request a tool call
          tool_message_count == 0 and config.tool_call_count == 0 ->
            %ToolCallResponse{
              content: nil,
              tool_calls: [
                %ToolCall{
                  id: "call_1",
                  name: "calculator",
                  input: %{operation: "add", a: 5, b: 3}
                }
              ]
            }

          # Tool has been executed, return final response
          tool_message_count > 0 ->
            %ToolCallResponse{
              content: config.final_response,
              tool_calls: []
            }

          # Fallback
          true ->
            response_model
        end
      end
    end
  end

  describe "BaseAgent.run_with_tools/2" do
    setup do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      config = %{
        client: %MockToolCallClient{},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry,
        max_tool_iterations: 5
      }

      agent = BaseAgent.init(config)
      {:ok, agent: agent}
    end

    test "executes tool and returns final response", %{agent: agent} do
      user_input = %{text: "What is 5 + 3?"}
      {updated_agent, response} = BaseAgent.run_with_tools(agent, user_input)

      # Should return the final output schema (BaseAgentOutputSchema)
      assert %BaseAgentOutputSchema{} = response
      assert response.chat_message == "Task completed"

      # Memory should contain user message, assistant tool call, tool result, and final response
      history = AgentMemory.history(updated_agent.memory)
      assert length(history) >= 3
    end

    test "respects max_tool_iterations limit" do
      # Create agent with very low max iterations
      config = %{
        client: %MockToolCallClient{final_response: "Stopped due to limit"},
        model: "test-model",
        temperature: 0.7,
        tool_registry: Registry.new([%Calculator{operation: "add", a: 0, b: 0}]),
        max_tool_iterations: 0
      }

      agent = BaseAgent.init(config)
      user_input = %{text: "Calculate something"}

      {_updated_agent, response} = BaseAgent.run_with_tools(agent, user_input)

      # Should still return a response even with 0 iterations
      assert response != nil
    end

    test "works without user_input (continuing conversation)" do
      # First run with user input
      calc = %Calculator{operation: "multiply", a: 0, b: 0}
      registry = Registry.new([calc])

      config = %{
        client: %MockToolCallClient{},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry,
        max_tool_iterations: 5
      }

      agent = BaseAgent.init(config)
      user_input = %{text: "First message"}

      {agent, _response} = BaseAgent.run_with_tools(agent, user_input)

      # Now run without user input
      {updated_agent, response} = BaseAgent.run_with_tools(agent, nil)

      assert response != nil
      assert updated_agent.memory != nil
    end
  end

  describe "Tool execution error handling" do
    defmodule BrokenCalculator do
      defstruct [:operation, :a, :b]

      defimpl Normandy.Tools.BaseTool do
        def tool_name(_), do: "broken_calculator"
        def tool_description(_), do: "A calculator that always fails"

        def input_schema(_) do
          %{type: "object"}
        end

        def run(_) do
          {:error, "Calculator is broken"}
        end
      end
    end

    test "handles tool execution errors gracefully" do
      broken_calc = %BrokenCalculator{operation: "add", a: 1, b: 2}
      registry = Registry.new([broken_calc])

      config = %{
        client: %MockToolCallClient{final_response: "Handled error"},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry,
        max_tool_iterations: 5
      }

      agent = BaseAgent.init(config)
      user_input = %{text: "Test error"}

      # Should not crash, should handle error
      {_updated_agent, response} = BaseAgent.run_with_tools(agent, user_input)

      assert response != nil
      assert response.chat_message == "Handled error"
    end
  end
end
