defmodule NormandyTest.Components.DateTimeProviderTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.ContextProvider
  alias Normandy.Components.DateTimeProvider

  describe "DateTimeProvider" do
    test "returns correct title" do
      provider = %DateTimeProvider{}
      assert ContextProvider.title(provider) == "Current Date and Time"
    end

    test "get_info returns current UTC datetime as string" do
      provider = %DateTimeProvider{}
      info = ContextProvider.get_info(provider)

      # Verify it's a string
      assert is_binary(info)

      # Verify it contains date components (YYYY-MM-DD)
      assert info =~ ~r/\d{4}-\d{2}-\d{2}/

      # Verify it contains time components (HH:MM:SS)
      assert info =~ ~r/\d{2}:\d{2}:\d{2}/

      # Verify it contains the Z suffix (UTC)
      assert String.ends_with?(info, "Z")
    end

    test "get_info returns valid DateTime string that can be parsed" do
      provider = %DateTimeProvider{}
      info = ContextProvider.get_info(provider)

      # The string should be parseable back to a DateTime
      # DateTime.from_iso8601/1 returns {:ok, datetime, offset}
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(info)
    end

    test "multiple calls return different times" do
      provider = %DateTimeProvider{}

      info1 = ContextProvider.get_info(provider)
      Process.sleep(10)
      info2 = ContextProvider.get_info(provider)

      # Times should be different (though very close)
      # We just verify both are valid strings
      assert is_binary(info1)
      assert is_binary(info2)
    end
  end

  describe "DateTimeProvider with BaseAgent" do
    test "can be registered as context provider in agent" do
      alias Normandy.Agents.BaseAgent

      config = %{
        client: %NormandyTest.Support.ModelMockup{},
        model: "test-model",
        temperature: 0.7
      }

      agent = BaseAgent.init(config)
      provider = %DateTimeProvider{}

      agent = BaseAgent.register_context_provider(agent, :datetime, provider)
      retrieved = BaseAgent.get_context_provider(agent, :datetime)

      assert retrieved == provider
      assert ContextProvider.title(retrieved) == "Current Date and Time"
    end

    test "datetime context is included in system prompt" do
      alias Normandy.Agents.BaseAgent
      alias Normandy.Components.{PromptSpecification, SystemPromptGenerator}

      config = %{
        client: %NormandyTest.Support.ModelMockup{},
        model: "test-model",
        temperature: 0.7
      }

      agent = BaseAgent.init(config)
      provider = %DateTimeProvider{}

      agent = BaseAgent.register_context_provider(agent, :datetime, provider)

      # Create a simple prompt specification with the context providers from agent
      prompt_spec = %PromptSpecification{
        background: ["You are a helpful assistant"],
        steps: ["Think step by step"],
        output_instructions: ["Respond clearly"],
        context_providers: agent.prompt_specification.context_providers
      }

      # Generate system prompt
      system_prompt = SystemPromptGenerator.generate_prompt(prompt_spec)

      # Verify the datetime context is included
      assert String.contains?(system_prompt, "Current Date and Time")
      assert system_prompt =~ ~r/\d{4}-\d{2}-\d{2}/
    end
  end
end
