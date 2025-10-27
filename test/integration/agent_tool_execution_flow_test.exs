defmodule Normandy.Integration.AgentToolExecutionFlowTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Tools.Examples.{Calculator, StringManipulator}
  alias NormandyTest.Support.IntegrationHelper

  @moduletag :integration
  @moduletag :api
  @moduletag timeout: 30_000

  setup do
    # These tests require a real API key
    # Skip by running: mix test --exclude api
    agent = IntegrationHelper.create_real_agent(temperature: 0.3)
    {:ok, agent: agent}
  end

  describe "Agent + Tool + LLM end-to-end flow" do
    test "agent executes tool and returns result", %{agent: agent} do
      # Register calculator tool
      calculator = %Calculator{operation: "add", a: 0, b: 0}
      agent = BaseAgent.register_tool(agent, calculator)

      # Ask agent to perform calculation
      {updated_agent, response} =
        BaseAgent.run(agent, %{chat_message: "What is 15 + 27?"})

      # Verify response contains the correct answer
      assert response.chat_message =~ "42"

      # Verify tool was executed (check memory for tool_use/tool_result)
      memory = updated_agent.memory
      history = memory.history

      # Should have: user message, assistant tool_use, tool_result, assistant response
      assert length(history) >= 3
    end
  end
end
