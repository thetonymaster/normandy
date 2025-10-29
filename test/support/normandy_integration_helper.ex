defmodule NormandyTest.Support.NormandyIntegrationHelper do
  @moduledoc """
  Helper functions for Normandy integration tests with real Anthropic API.
  """

  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Agents.BaseAgent

  @doc """
  Gets the Anthropic API key from environment.
  Checks both API_KEY (local) and ANTHROPIC_API_KEY (standard).
  """
  def get_api_key do
    System.get_env("API_KEY") || System.get_env("ANTHROPIC_API_KEY")
  end

  @doc """
  Checks if API key is available for testing.
  """
  def api_key_available? do
    get_api_key() != nil
  end

  @doc """
  Creates a real Claudio adapter client for testing.
  """
  def create_real_client(opts \\ []) do
    api_key = get_api_key()

    unless api_key do
      raise "API key required. Set API_KEY or ANTHROPIC_API_KEY environment variable."
    end

    %ClaudioAdapter{
      api_key: api_key,
      options:
        Keyword.get(opts, :options, %{
          timeout: 60_000,
          enable_caching: true,
          max_retries: 3
        })
    }
  end

  @doc """
  Creates an agent with real Claudio client for integration testing.
  """
  def create_real_agent(opts \\ []) do
    client = create_real_client()

    config = %{
      client: client,
      model: Keyword.get(opts, :model, "claude-sonnet-4-20250514"),
      temperature: Keyword.get(opts, :temperature, 0.7),
      max_tokens: Keyword.get(opts, :max_tokens, 1024)
    }

    BaseAgent.init(config)
  end

  @doc """
  Creates a simple calculator tool for testing.
  """
  def create_calculator_tool do
    %Normandy.Tools.Examples.Calculator{
      operation: "add",
      a: 0,
      b: 0
    }
  end

  @doc """
  Creates a weather tool for testing.

  This tool fetches real weather data, ensuring models must use it
  as they cannot know current weather conditions.
  """
  def create_weather_tool do
    %Normandy.Tools.Examples.Weather{
      city: ""
    }
  end
end
