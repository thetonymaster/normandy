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

  describe "unwrap_llm_content/1" do
    test "unwraps JSON with chat_message key" do
      content = "{\"chat_message\": \"actual text\"}"
      assert BaseAgent.unwrap_llm_content(content) == "actual text"
    end

    test "returns original content if not JSON" do
      content = "just some text"
      assert BaseAgent.unwrap_llm_content(content) == "just some text"
    end

    test "returns original content if JSON doesn't have chat_message" do
      content = "{\"other\": \"stuff\"}"
      assert BaseAgent.unwrap_llm_content(content) == "{\"other\": \"stuff\"}"
    end

    test "returns original if not a string" do
      assert BaseAgent.unwrap_llm_content(%{not: "a string"}) == %{not: "a string"}
    end
  end

  describe "telemetry" do
    test "emits telemetry events during run", %{agent: agent} do
      parent = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, _config ->
        send(parent, {ref, event, measurements, metadata})
      end

      events = [
        [:normandy, :agent, :run, :start],
        [:normandy, :agent, :run, :stop],
        [:normandy, :agent, :llm_call, :start],
        [:normandy, :agent, :llm_call, :stop]
      ]

      :telemetry.attach_many("test-handler", events, handler, nil)

      try do
        BaseAgent.run(agent, "hello")

        # Check for run events
        assert_receive {^ref, [:normandy, :agent, :run, :start], _ms, %{model: _}}
        assert_receive {^ref, [:normandy, :agent, :run, :stop], %{duration: _}, %{model: _}}

        # Check for LLM call events
        assert_receive {^ref, [:normandy, :agent, :llm_call, :start], _ms,
                        %{model: _, iteration: 1}}

        assert_receive {^ref, [:normandy, :agent, :llm_call, :stop], %{duration: _},
                        %{model: _, iteration: 1, has_tool_calls: false, tool_call_count: 0}}
      after
        :telemetry.detach("test-handler")
      end
    end
  end
end
