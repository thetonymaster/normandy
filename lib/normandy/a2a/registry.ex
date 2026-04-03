defmodule Normandy.A2A.Registry do
  @moduledoc """
  Helpers for discovering remote A2A agents and registering them as tools.

  ## Example

      alias Normandy.A2A.Registry, as: A2ARegistry
      alias Normandy.Tools.Registry

      registry = Registry.new()

      {:ok, registry} = A2ARegistry.discover_and_register(
        registry,
        "https://agent.example.com",
        auth_token: "bearer-token"
      )

  """

  alias Normandy.A2A.AgentTool
  alias Normandy.Tools.Registry

  @doc """
  Discovers a remote A2A agent and registers it as tool(s) in the registry.

  Creates one tool per skill if the agent has skills, or a single general
  tool if it has no skills.

  ## Options

    - `:auth_token` - Bearer token for authentication
    - `:transport_opts` - Options passed to the A2A transport (also used for discovery)
    - `:timeout` - Task completion timeout (default: 60s)

  """
  @spec discover_and_register(Registry.t(), String.t(), keyword()) ::
          {:ok, Registry.t()} | {:error, term()}
  def discover_and_register(%Registry{} = registry, base_url, opts \\ []) do
    transport_opts = Keyword.get(opts, :transport_opts, [])

    case Claudio.A2A.Client.discover(base_url, transport_opts) do
      {:ok, agent_card} ->
        endpoint = derive_endpoint(base_url, agent_card)
        tools = from_agent_card(agent_card, endpoint, opts)

        updated_registry =
          Enum.reduce(tools, registry, fn tool, reg ->
            Registry.register(reg, tool)
          end)

        {:ok, updated_registry}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Creates `AgentTool` structs from a pre-fetched agent card.

  Returns one tool per skill, or a single general tool if no skills.
  """
  @spec from_agent_card(Claudio.A2A.AgentCard.t(), String.t(), keyword()) :: [AgentTool.t()]
  def from_agent_card(agent_card, endpoint, opts \\ []) do
    tool_opts = Keyword.take(opts, [:auth_token, :transport_opts, :timeout])

    case agent_card.skills do
      [] ->
        [AgentTool.new(endpoint, agent_card, tool_opts)]

      skills ->
        Enum.map(skills, fn skill ->
          AgentTool.new(endpoint, agent_card, Keyword.put(tool_opts, :skill_id, skill.id))
        end)
    end
  end

  defp derive_endpoint(base_url, agent_card) do
    case agent_card.supported_interfaces do
      [interface | _] when not is_nil(interface.url) ->
        interface.url

      _ ->
        # Default: append /a2a to base URL
        String.trim_trailing(base_url, "/") <> "/a2a"
    end
  end
end
