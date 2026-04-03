defmodule Normandy.A2A.Server do
  @moduledoc """
  Exposes Normandy agents as A2A-compatible endpoints.

  Provides logic for building agent cards from Normandy agent configurations
  and handling incoming A2A messages by routing them through the agent.

  This module provides the logic layer only - it does not start an HTTP server.
  Integrate it into your web framework (e.g., Phoenix controller or Plug).

  ## Example

      # Build agent card
      card = Normandy.A2A.Server.build_agent_card(agent_config,
        name: "My Agent",
        description: "Helps with tasks",
        url: "https://myapp.com/a2a",
        version: "1.0.0"
      )

      # Handle incoming message (in your controller)
      {:ok, task} = Normandy.A2A.Server.handle_message(agent_config, a2a_message)

  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Tools.Registry

  @doc """
  Builds a `Claudio.A2A.AgentCard` from a Normandy agent configuration.

  Introspects registered tools to generate skill descriptions.

  ## Required Options

    - `:name` - Agent name
    - `:description` - Agent description

  ## Optional

    - `:url` - A2A endpoint URL
    - `:version` - Agent version
    - `:provider_url` - Provider URL
    - `:provider_org` - Provider organization name

  """
  @spec build_agent_card(BaseAgentConfig.t(), keyword()) :: Claudio.A2A.AgentCard.t()
  def build_agent_card(%BaseAgentConfig{} = config, opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)

    card = Claudio.A2A.AgentCard.new(name, description)

    card =
      case Keyword.get(opts, :version) do
        nil -> card
        version -> Claudio.A2A.AgentCard.set_version(card, version)
      end

    card =
      case {Keyword.get(opts, :provider_url), Keyword.get(opts, :provider_org)} do
        {nil, _} -> card
        {url, org} -> Claudio.A2A.AgentCard.set_provider(card, url, org || "")
      end

    card =
      case Keyword.get(opts, :url) do
        nil ->
          card

        url ->
          Claudio.A2A.AgentCard.add_interface(card, url, "jsonrpc+http", "0.3")
      end

    # Add skills from registered tools
    add_tool_skills(card, config.tool_registry)
  end

  @doc """
  Handles an incoming A2A message by routing it through the agent.

  Returns a `Claudio.A2A.Task` with the result as an artifact.
  """
  @spec handle_message(BaseAgentConfig.t(), Claudio.A2A.Message.t()) ::
          {:ok, Claudio.A2A.Task.t()} | {:error, term()}
  def handle_message(%BaseAgentConfig{} = config, %Claudio.A2A.Message{} = message) do
    # Extract text from message parts
    text =
      message.parts
      |> Enum.map(fn part -> Map.get(part, :text, "") end)
      |> Enum.join("\n")
      |> String.trim()

    # Build user input matching the agent's input schema
    user_input =
      case config.input_schema do
        %{chat_message: _} -> %{chat_message: text}
        _ -> text
      end

    try do
      {_updated_config, response} = BaseAgent.run(config, user_input)

      # Convert response to A2A task
      response_text = extract_response_text(response)

      task = %Claudio.A2A.Task{
        id: generate_task_id(),
        status: %{
          state: :completed,
          message: Claudio.A2A.Message.new(:agent, [Claudio.A2A.Part.text(response_text)]),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        },
        artifacts: [
          %Claudio.A2A.Artifact{
            artifact_id: "result-1",
            name: "response",
            parts: [Claudio.A2A.Part.text(response_text)]
          }
        ]
      }

      {:ok, task}
    rescue
      error ->
        require Logger

        Logger.error(
          "A2A Server handle_message failed: #{Exception.message(error)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        {:error, Exception.message(error)}
    end
  end

  defp add_tool_skills(card, nil), do: card

  defp add_tool_skills(card, %Registry{} = registry) do
    Registry.list(registry)
    |> Enum.reduce(card, fn tool, acc ->
      name = Normandy.Tools.BaseTool.tool_name(tool)
      description = Normandy.Tools.BaseTool.tool_description(tool)
      Claudio.A2A.AgentCard.add_skill(acc, name, description)
    end)
  end

  defp extract_response_text(response) when is_binary(response), do: response

  defp extract_response_text(response) when is_map(response) do
    cond do
      Map.has_key?(response, :chat_message) -> to_string(response.chat_message)
      Map.has_key?(response, :content) -> to_string(response.content)
      true -> inspect(response)
    end
  end

  defp extract_response_text(response), do: inspect(response)

  defp generate_task_id do
    "task-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
