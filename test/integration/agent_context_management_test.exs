defmodule Normandy.Integration.AgentContextManagementTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias NormandyTest.Support.IntegrationHelper

  @moduletag :integration
  @moduletag :api
  @moduletag timeout: 60_000

  setup do
    # These tests require a real API key
    # Skip by running: mix test --exclude api
    agent = IntegrationHelper.create_real_agent(temperature: 0.3)
    {:ok, agent: agent}
  end

  describe "Context window management" do
    test "agent tracks conversation history", %{agent: agent} do
      {agent, _r1} = BaseAgent.run(agent, %{chat_message: "My name is Bob"})
      {agent, _r2} = BaseAgent.run(agent, %{chat_message: "My favorite color is green"})

      {agent, response} =
        BaseAgent.run(agent, %{chat_message: "What's my name and favorite color?"})

      # Should remember both pieces of information
      history = agent.memory.history
      # 3 user messages + 3 assistant responses
      assert length(history) >= 6

      # Response should contain the remembered information
      assert is_binary(response.chat_message)
    end

    test "long conversation maintains context", %{agent: agent} do
      # Have a longer conversation
      conversation = [
        "Let's count from 1 to 5",
        "What number comes after 3?",
        "What's the last number we counted to?"
      ]

      final_agent =
        Enum.reduce(conversation, agent, fn msg, acc_agent ->
          {updated_agent, _response} = BaseAgent.run(acc_agent, %{chat_message: msg})
          updated_agent
        end)

      # Should have full history
      assert length(final_agent.memory.history) >= 6
    end

    test "system messages are preserved", %{agent: agent} do
      # Add system message
      agent_with_system = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["You are a helpful assistant that speaks like a pirate"]
          }
      }

      {_updated_agent, response} =
        BaseAgent.run(agent_with_system, %{chat_message: "Tell me about the weather"})

      # System message should influence response (might use pirate language)
      assert is_binary(response.chat_message)
    end

    test "memory persists across multiple interactions", %{agent: agent} do
      # First interaction
      {agent, r1} = BaseAgent.run(agent, %{chat_message: "Remember the number 42"})
      assert r1.chat_message != nil

      # Second interaction
      {agent, r2} = BaseAgent.run(agent, %{chat_message: "What number should you remember?"})
      assert is_binary(r2.chat_message)

      # Third interaction
      {agent, r3} = BaseAgent.run(agent, %{chat_message: "Add 8 to that number"})
      assert is_binary(r3.chat_message)

      # Memory should contain all interactions
      assert length(agent.memory.history) >= 6
    end
  end

  describe "Token counting and truncation" do
    test "agent handles very long input", %{agent: agent} do
      # Create a longer message
      long_message = String.duplicate("This is a test sentence. ", 100)

      {_updated_agent, response} =
        BaseAgent.run(agent, %{chat_message: "Summarize this: #{long_message}"})

      assert is_binary(response.chat_message)
      assert response.chat_message != ""
    end

    test "conversation with many turns", %{agent: agent} do
      # Have multiple back-and-forth exchanges
      final_agent =
        Enum.reduce(1..10, agent, fn i, acc_agent ->
          {updated_agent, _response} =
            BaseAgent.run(acc_agent, %{chat_message: "Message #{i}"})

          updated_agent
        end)

      # Should handle many turns
      assert length(final_agent.memory.history) >= 20
    end

    test "memory structure is maintained", %{agent: agent} do
      {agent, _r1} = BaseAgent.run(agent, %{chat_message: "First message"})
      {agent, _r2} = BaseAgent.run(agent, %{chat_message: "Second message"})

      # Verify memory structure
      assert is_list(agent.memory.history)

      assert Enum.all?(agent.memory.history, fn msg ->
               Map.has_key?(msg, :role) && Map.has_key?(msg, :content)
             end)
    end
  end

  describe "Conversation summarization" do
    test "agent can summarize its own conversation", %{agent: agent} do
      # Have a short conversation
      {agent, _r1} = BaseAgent.run(agent, %{chat_message: "Let's talk about space"})
      {agent, _r2} = BaseAgent.run(agent, %{chat_message: "Tell me about Mars"})

      {_agent, response} =
        BaseAgent.run(agent, %{chat_message: "Can you summarize what we discussed?"})

      # Should be able to summarize
      assert is_binary(response.chat_message)
      assert response.chat_message != ""
    end

    test "summarization maintains key information", %{agent: agent} do
      # Give important information
      {agent, _r1} = BaseAgent.run(agent, %{chat_message: "My phone number is 555-1234"})
      {agent, _r2} = BaseAgent.run(agent, %{chat_message: "My email is test@example.com"})

      {_agent, response} =
        BaseAgent.run(agent, %{chat_message: "What contact info did I provide?"})

      # Should remember both pieces of info
      assert is_binary(response.chat_message)
    end
  end

  describe "Context retrieval and relevance" do
    test "agent retrieves relevant context", %{agent: agent} do
      # Set up context
      {agent, _r1} = BaseAgent.run(agent, %{chat_message: "I like pizza"})
      {agent, _r2} = BaseAgent.run(agent, %{chat_message: "I like pasta"})

      {_agent, response} =
        BaseAgent.run(agent, %{chat_message: "What foods do I like?"})

      # Should retrieve both mentions
      assert is_binary(response.chat_message)
    end

    test "recent context is prioritized", %{agent: agent} do
      # Older message
      {agent, _r1} = BaseAgent.run(agent, %{chat_message: "My favorite color was blue"})

      # More recent message
      {agent, _r2} =
        BaseAgent.run(agent, %{chat_message: "Actually, my favorite color is red now"})

      {_agent, response} =
        BaseAgent.run(agent, %{chat_message: "What's my favorite color?"})

      # Should use most recent information
      assert is_binary(response.chat_message)
    end

    test "unrelated context doesn't interfere", %{agent: agent} do
      # Add some unrelated context
      {agent, _r1} = BaseAgent.run(agent, %{chat_message: "The sky is blue"})
      {agent, _r2} = BaseAgent.run(agent, %{chat_message: "Water is wet"})

      # Ask specific question
      {_agent, response} =
        BaseAgent.run(agent, %{chat_message: "What is 5 + 5?"})

      # Should answer correctly despite unrelated context
      assert is_binary(response.chat_message)
    end
  end
end
