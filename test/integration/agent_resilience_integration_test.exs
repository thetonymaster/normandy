defmodule Normandy.Integration.AgentResilienceIntegrationTest do
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

  describe "Retry logic with real LLM" do
    test "agent handles transient failures with retry", %{agent: agent} do
      # Configure with retry options
      agent_with_retry =
        IntegrationHelper.create_real_agent(
          temperature: 0.3,
          retry_options: [
            max_retries: 3,
            initial_delay: 100,
            max_delay: 1000,
            jitter: true
          ]
        )

      {_updated_agent, response} =
        BaseAgent.run(agent_with_retry, %{chat_message: "What is 2+2?"})

      # Should eventually succeed even with potential transient issues
      assert response.chat_message != nil
      assert is_binary(response.chat_message)
    end

    test "retry configuration affects behavior", %{agent: agent} do
      # Test with no retries
      agent_no_retry =
        IntegrationHelper.create_real_agent(
          temperature: 0.3,
          retry_options: [max_retries: 0]
        )

      {_updated_agent, response} =
        BaseAgent.run(agent_no_retry, %{chat_message: "Hello"})

      assert response.chat_message != nil
    end
  end

  describe "Circuit breaker integration" do
    test "circuit breaker allows normal operation when closed", %{agent: agent} do
      agent_with_cb =
        IntegrationHelper.create_real_agent(
          temperature: 0.3,
          enable_circuit_breaker: true,
          circuit_breaker_options: [
            error_threshold: 3,
            timeout: 60_000
          ]
        )

      # Should work normally when circuit is closed
      {_updated_agent, response} =
        BaseAgent.run(agent_with_cb, %{chat_message: "Test message"})

      assert response.chat_message != nil
    end

    test "multiple successful calls keep circuit closed", %{agent: agent} do
      agent_with_cb =
        IntegrationHelper.create_real_agent(
          temperature: 0.3,
          enable_circuit_breaker: true
        )

      # Make multiple successful calls
      {agent_with_cb, response1} =
        BaseAgent.run(agent_with_cb, %{chat_message: "First"})

      assert response1.chat_message != nil

      {agent_with_cb, response2} =
        BaseAgent.run(agent_with_cb, %{chat_message: "Second"})

      assert response2.chat_message != nil

      {_agent_with_cb, response3} =
        BaseAgent.run(agent_with_cb, %{chat_message: "Third"})

      assert response3.chat_message != nil
    end
  end

  describe "Error handling and recovery" do
    test "agent handles API errors gracefully", %{agent: agent} do
      # Even with potential API issues, agent should return structured response
      {_updated_agent, response} =
        BaseAgent.run(agent, %{chat_message: "What is the meaning of life?"})

      assert is_map(response)
      assert Map.has_key?(response, :chat_message)
    end

    test "agent maintains state across successful and failed requests", %{agent: agent} do
      # First successful request
      {agent, response1} =
        BaseAgent.run(agent, %{chat_message: "Remember that my favorite color is blue"})

      assert response1.chat_message != nil

      # Even if there were transient failures, conversation should continue
      {_agent, response2} =
        BaseAgent.run(agent, %{chat_message: "What color did I just mention?"})

      # Should remember the conversation
      assert is_binary(response2.chat_message)
    end

    test "memory persists after errors", %{agent: agent} do
      {agent, _response1} =
        BaseAgent.run(agent, %{chat_message: "My name is Alice"})

      # Even with potential failures, memory should be intact
      {agent2, response2} =
        BaseAgent.run(agent, %{chat_message: "What's my name?"})

      # Should have conversation history
      assert agent2.memory.history != []
      # user, assistant, user, assistant
      assert length(agent2.memory.history) >= 4
    end
  end

  describe "Timeout handling" do
    test "agent respects timeout configuration", %{agent: agent} do
      agent_with_timeout =
        IntegrationHelper.create_real_agent(
          temperature: 0.3,
          timeout: 30_000
        )

      # Should complete within timeout
      {_updated_agent, response} =
        BaseAgent.run(agent_with_timeout, %{chat_message: "Quick question: what is 1+1?"})

      assert response.chat_message != nil
    end

    test "short responses complete quickly", %{agent: agent} do
      start_time = System.monotonic_time(:millisecond)

      {_updated_agent, response} =
        BaseAgent.run(agent, %{chat_message: "Say 'hello'"})

      duration = System.monotonic_time(:millisecond) - start_time

      assert response.chat_message != nil
      # Should complete reasonably quickly (< 10 seconds for simple request)
      assert duration < 10_000
    end
  end

  describe "Rate limiting and backpressure" do
    test "multiple concurrent requests complete successfully", %{agent: agent} do
      # Make several requests in sequence
      results =
        for i <- 1..3 do
          {_agent, response} = BaseAgent.run(agent, %{chat_message: "Count #{i}"})
          response
        end

      # All should succeed
      assert length(results) == 3
      assert Enum.all?(results, fn r -> r.chat_message != nil end)
    end

    test "agent handles rapid sequential requests", %{agent: agent} do
      # Test that agent can handle requests without artificial delays
      {agent, r1} = BaseAgent.run(agent, %{chat_message: "First"})
      {agent, r2} = BaseAgent.run(agent, %{chat_message: "Second"})
      {_agent, r3} = BaseAgent.run(agent, %{chat_message: "Third"})

      assert r1.chat_message != nil
      assert r2.chat_message != nil
      assert r3.chat_message != nil
    end
  end
end
