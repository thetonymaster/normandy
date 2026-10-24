defmodule NormandyTest.Components.DateTimeProviderTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.ContextProvider
  alias Normandy.Components.DateTimeProvider

  describe "DateTimeProvider" do
    test "returns the title" do
      assert ContextProvider.title(%DateTimeProvider{}) == "Current Date"
    end

    test "get_info is today's UTC date in ISO 8601, with no time (stable across calls)" do
      info = ContextProvider.get_info(%DateTimeProvider{})

      assert info =~ ~r/\A\d{4}-\d{2}-\d{2}\z/
      date = Date.from_iso8601!(info)
      # Tolerate a run that straddles midnight UTC.
      assert Date.diff(Date.utc_today(), date) in [0, 1]
    end

    test "two calls in a row return the same text (the prompt prefix stays cacheable)" do
      provider = %DateTimeProvider{}
      first = ContextProvider.get_info(provider)
      second = ContextProvider.get_info(provider)

      assert first == second or
               Date.diff(Date.from_iso8601!(second), Date.from_iso8601!(first)) == 1
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
      retrieved = BaseAgent.fetch_context_provider!(agent, :datetime)

      assert retrieved == provider
      assert ContextProvider.title(retrieved) == "Current Date"
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
      assert String.contains?(system_prompt, "Current Date")
      assert system_prompt =~ ~r/\d{4}-\d{2}-\d{2}/
    end
  end
end
