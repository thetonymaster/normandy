defmodule Normandy.Integration.BasicAgentTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.AgentMemory
  alias NormandyTest.Support.NormandyIntegrationHelper

  @moduletag :normandy_integration
  @moduletag :api
  @moduletag timeout: 60_000

  setup do
    unless NormandyIntegrationHelper.api_key_available?() do
      {:skip, "API key not available. Set API_KEY or ANTHROPIC_API_KEY environment variable."}
    else
      # Configure Claudio timeout for API requests
      Application.put_env(:claudio, Claudio.Client, timeout: 60_000, recv_timeout: 120_000)

      agent = NormandyIntegrationHelper.create_real_agent(temperature: 0.3)
      {:ok, agent: agent}
    end
  end

  describe "Basic agent conversation" do
    test "agent responds to simple question", %{agent: agent} do
      {_updated_agent, response} =
        BaseAgent.run(agent, %{chat_message: "What is 2+2? Just give me the number."})

      assert is_binary(response.chat_message)
      assert response.chat_message =~ "4"
    end

    test "agent maintains conversation context", %{agent: agent} do
      {agent, response1} =
        BaseAgent.run(agent, %{chat_message: "I like apples."})

      assert is_binary(response1.chat_message)

      {_agent, response2} =
        BaseAgent.run(agent, %{chat_message: "What fruit did I say I like?"})

      assert is_binary(response2.chat_message)
      assert String.downcase(response2.chat_message) =~ "apple"
    end
  end

  describe "Agent with tools" do
    test "agent uses calculator tool", %{agent: agent} do
      calculator = NormandyIntegrationHelper.create_calculator_tool()
      agent = BaseAgent.register_tool(agent, calculator)

      {updated_agent, response} =
        BaseAgent.run(agent, %{chat_message: "Calculate 15 + 27 using the calculator tool."})

      assert is_binary(response.chat_message)
      assert response.chat_message =~ "42"

      # Verify tool was used in conversation history
      history = AgentMemory.history(updated_agent.memory)

      # Look for assistant message with tool_use content blocks
      has_tool_use =
        Enum.any?(history, fn msg ->
          msg.role == "assistant" && is_list(msg.content) &&
            Enum.any?(msg.content, fn
              %{type: "tool_use"} -> true
              %{type: :tool_use} -> true
              _ -> false
            end)
        end)

      assert has_tool_use, "Expected tool_use in conversation history"
    end
  end
end
