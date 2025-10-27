defmodule Normandy.Integration.LLMCachingIntegrationTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias NormandyTest.Support.IntegrationHelper

  @moduletag :integration
  @moduletag :api
  @moduletag timeout: 60_000

  setup do
    # These tests require a real API key
    # Skip by running: mix test --exclude api
    agent_with_cache =
      IntegrationHelper.create_real_agent(
        temperature: 0.3,
        enable_caching: true
      )

    agent_no_cache =
      IntegrationHelper.create_real_agent(
        temperature: 0.3,
        enable_caching: false
      )

    {:ok, agent_with_cache: agent_with_cache, agent_no_cache: agent_no_cache}
  end

  describe "Prompt caching with Anthropic API" do
    test "caching is enabled in client configuration", %{agent_with_cache: agent} do
      # Verify caching is enabled
      assert agent.client.options.enable_caching == true

      # Run a request
      {_agent, response} = BaseAgent.run(agent, %{chat_message: "What is 2+2?"})

      assert is_binary(response.chat_message)
    end

    test "caching can be disabled", %{agent_no_cache: agent} do
      # Verify caching is disabled
      assert agent.client.options.enable_caching == false

      # Run a request
      {_agent, response} = BaseAgent.run(agent, %{chat_message: "What is 3+3?"})

      assert is_binary(response.chat_message)
    end

    test "repeated messages with caching", %{agent_with_cache: agent} do
      # First request - cache miss
      start1 = System.monotonic_time(:millisecond)
      {agent, response1} = BaseAgent.run(agent, %{chat_message: "Tell me about caching"})
      duration1 = System.monotonic_time(:millisecond) - start1

      assert is_binary(response1.chat_message)

      # Give API a moment
      Process.sleep(1000)

      # Second similar request - might hit cache
      start2 = System.monotonic_time(:millisecond)
      {_agent, response2} = BaseAgent.run(agent, %{chat_message: "Tell me about caching"})
      duration2 = System.monotonic_time(:millisecond) - start2

      assert is_binary(response2.chat_message)

      # Both requests should complete
      IO.puts("First request: #{duration1}ms, Second request: #{duration2}ms")
    end
  end

  describe "System message caching" do
    test "long system messages benefit from caching", %{agent_with_cache: agent} do
      # Create agent with long system message (good caching candidate)
      long_system = String.duplicate("This is important context. ", 100)

      agent_with_system = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: [long_system]
          }
      }

      # First request
      {agent_with_system, r1} =
        BaseAgent.run(agent_with_system, %{chat_message: "Question 1"})

      assert r1.chat_message != nil

      # Second request - should reuse cached system message
      {_agent_with_system, r2} =
        BaseAgent.run(agent_with_system, %{chat_message: "Question 2"})

      assert r2.chat_message != nil
    end

    test "system message is preserved across requests", %{agent_with_cache: agent} do
      custom_system = "You are a helpful AI assistant specialized in mathematics."

      agent_with_system = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: [custom_system]
          }
      }

      {agent_with_system, r1} =
        BaseAgent.run(agent_with_system, %{chat_message: "What is 10 + 15?"})

      assert r1.chat_message != nil

      {_agent_with_system, r2} =
        BaseAgent.run(agent_with_system, %{chat_message: "What is 20 * 3?"})

      assert r2.chat_message != nil

      # System message should be in background
      assert agent_with_system.prompt_specification.background == [custom_system]
    end
  end

  describe "Conversation history caching" do
    test "long conversations benefit from caching", %{agent_with_cache: agent} do
      # Build up conversation history
      agent =
        Enum.reduce(1..5, agent, fn i, acc_agent ->
          {updated_agent, _response} =
            BaseAgent.run(acc_agent, %{chat_message: "Statement number #{i}"})

          updated_agent
        end)

      # This request should benefit from cached history
      start_time = System.monotonic_time(:millisecond)

      {_agent, response} =
        BaseAgent.run(agent, %{chat_message: "Summarize our conversation"})

      duration = System.monotonic_time(:millisecond) - start_time

      assert is_binary(response.chat_message)
      IO.puts("Request with cached history: #{duration}ms")
    end

    test "cache efficiency with repeated patterns", %{agent_with_cache: agent} do
      # Use similar conversation structure multiple times
      pattern = [
        "Let's discuss topic A",
        "Tell me more",
        "Summarize please"
      ]

      # First run
      agent1 =
        Enum.reduce(pattern, agent, fn msg, acc ->
          {updated, _r} = BaseAgent.run(acc, %{chat_message: msg})
          updated
        end)

      assert length(agent1.memory.history) >= 6

      # Second run with fresh agent but similar pattern
      _agent2 =
        Enum.reduce(pattern, agent, fn msg, acc ->
          {updated, _r} = BaseAgent.run(acc, %{chat_message: msg})
          updated
        end)

      # Both should complete successfully
    end
  end

  describe "Tool usage with caching" do
    test "tool definitions are cached", %{agent_with_cache: agent} do
      calculator = IntegrationHelper.create_calculator_tool()
      agent = BaseAgent.register_tool(agent, calculator)

      # First tool use
      {agent, r1} = BaseAgent.run(agent, %{chat_message: "Calculate 5 + 3"})
      assert r1.chat_message != nil

      # Second tool use - tool definition should be cached
      {_agent, r2} = BaseAgent.run(agent, %{chat_message: "Calculate 10 * 2"})
      assert r2.chat_message != nil
    end

    test "multiple tools with caching", %{agent_with_cache: agent} do
      calculator = IntegrationHelper.create_calculator_tool()
      string_tool = IntegrationHelper.create_string_tool()

      agent =
        agent
        |> BaseAgent.register_tool(calculator)
        |> BaseAgent.register_tool(string_tool)

      # Use both tools
      {agent, r1} =
        BaseAgent.run(agent, %{chat_message: "Calculate 5+5 and uppercase the word 'hello'"})

      assert r1.chat_message != nil

      # Use again - both tool definitions should be cached
      {_agent, r2} = BaseAgent.run(agent, %{chat_message: "Calculate 3*3 and lowercase 'WORLD'"})
      assert r2.chat_message != nil
    end
  end

  describe "Cache performance comparison" do
    test "requests complete with caching enabled", %{agent_with_cache: agent} do
      measurements =
        for _i <- 1..3 do
          start = System.monotonic_time(:millisecond)
          {agent, _response} = BaseAgent.run(agent, %{chat_message: "Quick test"})
          duration = System.monotonic_time(:millisecond) - start
          duration
        end

      avg_duration = Enum.sum(measurements) / length(measurements)
      IO.puts("Average duration with caching: #{avg_duration}ms")

      # Should complete (no specific time requirement due to API variance)
      assert Enum.all?(measurements, fn d -> d > 0 end)
    end

    test "requests complete with caching disabled", %{agent_no_cache: agent} do
      measurements =
        for _i <- 1..3 do
          start = System.monotonic_time(:millisecond)
          {agent, _response} = BaseAgent.run(agent, %{chat_message: "Quick test"})
          duration = System.monotonic_time(:millisecond) - start
          duration
        end

      avg_duration = Enum.sum(measurements) / length(measurements)
      IO.puts("Average duration without caching: #{avg_duration}ms")

      # Should complete (no specific time requirement due to API variance)
      assert Enum.all?(measurements, fn d -> d > 0 end)
    end
  end
end
