defmodule AgentHorde.Clients do
  @moduledoc """
  Builds LLM provider client structs from environment variables.

  All secrets are read from the environment at call time — nothing is
  hardcoded or logged.
  """

  alias Normandy.LLM.{ClaudioAdapter, OpenAICompatibleAdapter}

  @doc "Anthropic Claude client (uses ANTHROPIC_API_KEY)."
  def claude do
    %ClaudioAdapter{
      api_key: System.get_env("ANTHROPIC_API_KEY"),
      options: %{timeout: 120_000}
    }
  end

  @doc "OpenAI client (uses OPENAI_API_KEY)."
  def openai do
    %OpenAICompatibleAdapter{
      api_key: System.get_env("OPENAI_API_KEY"),
      base_url: "https://api.openai.com/v1",
      options: %{timeout: 120_000}
    }
  end

  @doc "DigitalOcean Inference client (uses DO_INFERENCE_KEY and DO_INFERENCE_URL)."
  def do_client do
    %OpenAICompatibleAdapter{
      api_key: System.get_env("DO_INFERENCE_KEY"),
      base_url: System.get_env("DO_INFERENCE_URL"),
      options: %{timeout: 120_000}
    }
  end

  @doc """
  Returns the three analyst provider tuples: `{label, client, model_string}`.

      [
        {"Claude",      claude(),    "claude-sonnet-4-6"},
        {"GPT-4o",      openai(),    "gpt-4o"},
        {"Llama (DO)",  do_client(), "llama3.3-70b-instruct"}
      ]
  """
  def providers do
    [
      {"Claude", claude(), "claude-sonnet-4-6"},
      {"GPT-4o", openai(), "gpt-4o"},
      {"Llama (DO)", do_client(), "llama3.3-70b-instruct"}
    ]
  end
end
