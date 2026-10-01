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

  alias Claudio.A2A.AgentCard
  alias Claudio.A2A.Message
  alias Claudio.A2A.Part
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Tools.BaseTool
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
    - `:expose_tools` - tool names to list as skills in the public card, or `:all`.
      Default: none, so an internal or privileged tool is not advertised unless
      you choose to.

  """
  @spec build_agent_card(BaseAgentConfig.t(), keyword()) :: Claudio.A2A.AgentCard.t()
  def build_agent_card(%BaseAgentConfig{} = config, opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)

    card = AgentCard.new(name, description)

    card =
      case Keyword.get(opts, :version) do
        nil -> card
        version -> AgentCard.set_version(card, version)
      end

    card =
      case {Keyword.get(opts, :provider_url), Keyword.get(opts, :provider_org)} do
        {nil, _} -> card
        {url, org} -> AgentCard.set_provider(card, url, org || "")
      end

    card =
      case Keyword.get(opts, :url) do
        nil ->
          card

        url ->
          AgentCard.add_interface(card, url, "jsonrpc+http", "0.3")
      end

    add_tool_skills(card, config.tool_registry, Keyword.get(opts, :expose_tools, []))
  end

  @doc """
  Handles an incoming A2A message by routing it through the agent.

  Returns a `Claudio.A2A.Task` with the result as an artifact, or:

    - `{:error, :no_text}` - the message has no text part (file or data parts
      alone are not run as an empty prompt)
    - `{:error, :agent_failed}` - the agent raised or exited. The remote caller
      gets only this; the detail is logged.

  Each call runs on the given `config`: the A2A `context_id` and `task_id` do
  not carry memory between calls.
  """
  @spec handle_message(BaseAgentConfig.t(), Claudio.A2A.Message.t()) ::
          {:ok, Claudio.A2A.Task.t()} | {:error, term()}
  def handle_message(%BaseAgentConfig{} = config, %Claudio.A2A.Message{} = message) do
    case message_text(message) do
      "" -> {:error, :no_text}
      text -> run_agent(config, text)
    end
  end

  defp message_text(message) do
    message.parts
    |> Enum.map_join("\n", fn part -> Map.get(part, :text) || "" end)
    |> String.trim()
  end

  defp run_agent(config, text) do
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
          message: Message.new(:agent, [Part.text(response_text)]),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        },
        artifacts: [
          %Claudio.A2A.Artifact{
            artifact_id: "result-1",
            name: "response",
            parts: [Part.text(response_text)]
          }
        ]
      }

      {:ok, task}
    rescue
      error ->
        agent_failed(Exception.format(:error, error, __STACKTRACE__))
    catch
      :exit, reason ->
        agent_failed(Exception.format(:exit, reason, __STACKTRACE__))
    end
  end

  # The remote caller is outside this system: it gets a generic error, and the
  # detail (which can name internals) stays in the log.
  defp agent_failed(detail) do
    require Logger
    Logger.error("A2A Server handle_message: the agent failed\n" <> detail)
    {:error, :agent_failed}
  end

  defp add_tool_skills(card, nil, _expose), do: card

  defp add_tool_skills(card, %Registry{} = registry, expose) do
    registry
    |> Registry.list()
    |> Enum.filter(&(expose == :all or BaseTool.tool_name(&1) in expose))
    |> Enum.reduce(card, fn tool, acc ->
      AgentCard.add_skill(acc, BaseTool.tool_name(tool), BaseTool.tool_description(tool))
    end)
  end

  defp extract_response_text(response) when is_binary(response), do: response

  # Anything else goes out as the schema's JSON (its declared fields only), never
  # inspect/1 output, which would show the remote caller internal metadata. A
  # value with no BaseIOSchema encoding raises, and the caller gets :agent_failed.
  defp extract_response_text(response) when is_map(response) do
    cond do
      Map.has_key?(response, :chat_message) -> to_string(response.chat_message)
      Map.has_key?(response, :content) -> to_string(response.content)
      true -> BaseIOSchema.to_json(response)
    end
  end

  defp extract_response_text(response), do: BaseIOSchema.to_json(response)

  defp generate_task_id do
    "task-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
