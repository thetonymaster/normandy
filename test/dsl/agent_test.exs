defmodule Normandy.DSL.AgentTest do
  use ExUnit.Case, async: true

  # Define a test agent using the DSL
  defmodule TestAgent do
    use Normandy.DSL.Agent

    agent do
      name("Test Agent")
      description("A test agent")
      model("claude-haiku-4-5-20251001")
      temperature(0.8)
      max_tokens(2048)
      system_prompt("You are a test agent.")
    end
  end

  # Define an agent with structured prompt
  defmodule StructuredAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      background("Background context")
      steps("1. Think\n2. Respond")
      output_instructions("Format as JSON")
    end
  end

  # Define an agent with max_messages
  defmodule LimitedMemoryAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      max_messages(10)
    end
  end

  describe "agent definition" do
    test "config/0 returns agent configuration" do
      config = TestAgent.config()

      assert config.name == "Test Agent"
      assert config.description == "A test agent"
      assert config.model == "claude-haiku-4-5-20251001"
      assert config.temperature == 0.8
      assert config.max_tokens == 2048
      assert config.system_prompt == "You are a test agent."
    end

    test "config/0 with structured prompt" do
      config = StructuredAgent.config()

      assert config.model == "claude-haiku-4-5-20251001"
      assert config.background == "Background context"
      assert config.steps == "1. Think\n2. Respond"
      assert config.output_instructions == "Format as JSON"
    end

    test "config/0 with max_messages" do
      config = LimitedMemoryAgent.config()

      assert config.model == "claude-haiku-4-5-20251001"
      assert config.max_messages == 10
    end
  end

  describe "new/1" do
    test "creates agent with required client" do
      client = %NormandyTest.Support.ModelMockup{}

      {:ok, agent} = TestAgent.new(client: client)

      assert agent.client == client
      assert agent.model == "claude-haiku-4-5-20251001"
      assert agent.temperature == 0.8
      assert agent.max_tokens == 2048
    end

    test "applies system prompt" do
      client = %NormandyTest.Support.ModelMockup{}

      {:ok, agent} = TestAgent.new(client: client)

      assert agent.prompt_specification != nil
      assert agent.prompt_specification.background == ["You are a test agent."]
    end

    test "applies structured prompt" do
      client = %NormandyTest.Support.ModelMockup{}

      {:ok, agent} = StructuredAgent.new(client: client)

      assert agent.prompt_specification.background == ["Background context"]
      assert agent.prompt_specification.steps == ["1. Think\n2. Respond"]
      assert agent.prompt_specification.output_instructions == ["Format as JSON"]
    end

    test "supports override options" do
      client = %NormandyTest.Support.ModelMockup{}

      {:ok, agent} =
        TestAgent.new(
          client: client,
          override: [temperature: 0.5, max_tokens: 1024]
        )

      assert agent.temperature == 0.5
      assert agent.max_tokens == 1024
    end

    test "raises when client is missing" do
      assert_raise KeyError, fn ->
        TestAgent.new([])
      end
    end
  end

  describe "run/2" do
    test "runs agent with string input" do
      client = %NormandyTest.Support.ModelMockup{}
      {:ok, agent} = TestAgent.new(client: client)

      {_updated_agent, response} = TestAgent.run(agent, "test input")

      assert is_map(response)
    end

    test "runs agent with map input" do
      client = %NormandyTest.Support.ModelMockup{}
      {:ok, agent} = TestAgent.new(client: client)

      {_updated_agent, response} = TestAgent.run(agent, %{chat_message: "test"})

      assert is_map(response)
    end
  end

  describe "reset_memory/1" do
    test "resets agent memory" do
      client = %NormandyTest.Support.ModelMockup{}
      {:ok, agent} = TestAgent.new(client: client)

      # Run to add to memory
      {agent, _} = TestAgent.run(agent, "first message")
      assert length(agent.memory.history) > 0

      # Reset
      agent = TestAgent.reset_memory(agent)
      assert length(agent.memory.history) == 0
    end
  end

  describe "integration" do
    test "full agent lifecycle" do
      client = %NormandyTest.Support.ModelMockup{}

      # Create agent
      {:ok, agent} = TestAgent.new(client: client)
      assert agent != nil

      # Run once
      {agent, response1} = TestAgent.run(agent, "hello")
      assert is_map(response1)
      assert length(agent.memory.history) > 0

      # Run again (memory should accumulate)
      {agent, response2} = TestAgent.run(agent, "goodbye")
      assert is_map(response2)
      assert length(agent.memory.history) > 2

      # Reset and verify
      agent = TestAgent.reset_memory(agent)
      assert length(agent.memory.history) == 0
    end
  end
end
