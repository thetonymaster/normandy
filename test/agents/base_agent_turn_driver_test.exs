defmodule Normandy.Agents.BaseAgentTurnDriverTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Components.AgentMemory

  # Re-uses the project-wide ModelMockup: converse/completitions return
  # response_model as-is, giving deterministic LLM responses without network.

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
end
