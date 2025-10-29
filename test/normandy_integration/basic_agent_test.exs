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
    test "agent uses weather tool to fetch real-time data" do
      # Use Sonnet for better tool usage reliability
      agent =
        NormandyIntegrationHelper.create_real_agent(
          model: "claude-sonnet-4-5-20250929",
          temperature: 0.3
        )

      weather = NormandyIntegrationHelper.create_weather_tool()
      agent = BaseAgent.register_tool(agent, weather)

      # Ask for real-time weather - model cannot know this without using the tool
      {updated_agent, response} =
        BaseAgent.run(agent, %{chat_message: "What's the current weather in San Francisco?"})

      assert is_binary(response.chat_message)
      # Response should contain weather-related information
      assert String.downcase(response.chat_message) =~ ~r/temperature|weather|celsius|°c/

      # Verify tool was actually used in conversation history
      history = AgentMemory.history(updated_agent.memory)

      # Look for assistant message with tool_use content blocks
      # Content is stored as JSON strings, so we need to parse and check
      has_tool_use =
        Enum.any?(history, fn msg ->
          if msg.role == "assistant" do
            case Poison.decode(msg.content) do
              {:ok, content_list} when is_list(content_list) ->
                Enum.any?(content_list, fn item ->
                  Map.get(item, "type") == "tool_use"
                end)

              _ ->
                false
            end
          else
            false
          end
        end)

      assert has_tool_use,
             "Expected tool_use in conversation history - model should have used the weather tool to fetch real-time data"
    end
  end
end
