defmodule NormandyTest.BaseAgentsTest do
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.BaseAgentConfig
  alias NormandyTest.Support.ContextProvider
  alias Normandy.Components.Message
  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.AgentMemory
  alias Normandy.Agents.BaseAgent
  use ExUnit.Case, async: true

  setup do
    config = %{
      client: %NormandyTest.Support.ModelMockup{},
      model: "claude-haiku-4-5-20251001",
      temperature: 0.9
    }

    agent = BaseAgent.init(config)
    {:ok, %{agent: agent}}
  end

  test "initialize_agent", %{agent: agent} do
    assert Map.get(agent, :input_schema) == %Normandy.Agents.BaseAgentInputSchema{}
    assert Map.get(agent, :output_schema) == %Normandy.Agents.BaseAgentOutputSchema{}
    assert Map.get(agent, :memory) == AgentMemory.new_memory()
    assert Map.get(agent, :initial_memory) == Map.get(agent, :memory)
    assert Map.get(agent, :prompt_specification) == %PromptSpecification{}
    assert Map.get(agent, :client) == %NormandyTest.Support.ModelMockup{}
    assert Map.get(agent, :model) == "claude-haiku-4-5-20251001"
    assert Map.get(agent, :temperature) == 0.9
    assert Map.get(agent, :max_tokens) == nil
  end

  test "reset memory", %{agent: agent} do
    initial_memory = agent.initial_memory

    agent = BaseAgent.reset_memory(agent)
    assert agent.memory == initial_memory
  end

  test "get response", %{agent: agent} do
    mock_memory =
      AgentMemory.new_memory()
      |> Map.put(:history, [%Message{role: "user", content: "hello"}])

    agent = Map.put(agent, :memory, mock_memory)

    response = BaseAgent.get_response(agent)

    assert response == %Normandy.Agents.BaseAgentOutputSchema{}
  end

  test "get context provider", %{agent: agent = %BaseAgentConfig{prompt_specification: prompt}} do
    mock_provider = %ContextProvider{}

    context_providers =
      prompt
      |> Map.get(:context_providers)
      |> Map.put(:ctx, mock_provider)

    prompt = Map.put(prompt, :context_providers, context_providers)
    agent = Map.put(agent, :prompt_specification, prompt)

    ctx = BaseAgent.get_context_provider(agent, :ctx)
    assert ctx == mock_provider

    assert_raise Normandy.NonExistentContextProvider,
                 "context provider :not_exists does not exist",
                 fn ->
                   BaseAgent.get_context_provider(agent, :not_exists)
                 end
  end

  test "register context provider", %{agent: agent} do
    ctx = %ContextProvider{}
    agent = BaseAgent.register_context_provider(agent, :ctx, ctx)

    context_provider =
      Map.get(agent, :prompt_specification)
      |> Map.get(:context_providers)
      |> Map.get(:ctx)

    assert ctx == context_provider
  end

  test "delete a context provider", %{agent: agent} do
    ctx = %ContextProvider{}
    agent = BaseAgent.register_context_provider(agent, :ctx, ctx)

    context_provider =
      Map.get(agent, :prompt_specification)
      |> Map.get(:context_providers)
      |> Map.get(:ctx)

    assert ctx == context_provider

    agent = BaseAgent.delete_context_provider(agent, :ctx)

    context_provider =
      Map.get(agent, :prompt_specification)
      |> Map.get(:context_providers)
      |> Map.get(:ctx)

    refute context_provider
  end

  test "run", %{agent: agent} do
    mock_input = %BaseAgentInputSchema{chat_message: "hello"}
    mock_output = %BaseAgentOutputSchema{}

    {agent, response} = BaseAgent.run(agent, mock_input)
    assert response == mock_output
    assert Map.get(agent, :current_user_input) == mock_input
  end

  test "rich base agent io str and rich" do
    test_io = %Normandy.Agents.BaseAgentInputSchema{chat_message: "chat message"}

    assert Normandy.Components.BaseIOSchema.__str__(test_io) ==
             "{\"chat_message\":\"chat message\"}"

    assert Normandy.Components.BaseIOSchema.__rich__(test_io) != nil
  end
end
