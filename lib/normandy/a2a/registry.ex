defmodule Normandy.A2A.Registry do
  @moduledoc """
  Helpers for discovering remote A2A agents and registering them as tools.

  ## Example

      alias Normandy.A2A.Registry, as: A2ARegistry
      alias Normandy.Tools.Toolset

      registry = Toolset.new()

      {:ok, registry} = A2ARegistry.discover_and_register(
        registry,
        "https://agent.example.com",
        prefix: "research",
        auth_token: "bearer-token"
      )

  `:prefix` is required: see `Normandy.A2A.AgentTool`'s "Tool names" and "Trust".
  """

  alias Claudio.A2A.Client
  alias Normandy.A2A.AgentTool
  alias Normandy.Options
  alias Normandy.Tools.Toolset

  # AgentTool.new/3's options except :skill_id, which from_agent_card/3 sets per skill.
  @card_opts Keyword.delete(AgentTool.__opts_schema__(:new).schema, :skill_id)
  @from_agent_card_opts_schema NimbleOptions.new!(@card_opts)
  # Task 3.4c: discover_and_register/3's :timeout is each tool's registration timeout.
  @discover_and_register_opts_schema NimbleOptions.new!(
                                       @card_opts ++
                                         [
                                           timeout: [
                                             type: :pos_integer,
                                             default: 60_000,
                                             doc:
                                               "Each tool's registration timeout, in positive ms " <>
                                                 "(`Normandy.Tools.Toolset.register/3`; " <>
                                                 "60_000 as in 1.x)."
                                           ]
                                         ]
                                     )

  @doc """
  Discovers a remote A2A agent and registers it as tool(s) in the toolset.

  Creates one tool per skill if the agent has skills, or a single general
  tool if it has no skills.

  `:transport_opts` is also used for discovery.

  ## Options

  #{Options.docs(@discover_and_register_opts_schema)}
  """
  @spec discover_and_register(Toolset.t(), String.t(), keyword()) ::
          {:ok, Toolset.t()} | {:error, term()}
  def discover_and_register(%Toolset{} = registry, base_url, opts \\ []) do
    opts =
      Options.validate!(
        opts,
        @discover_and_register_opts_schema,
        {__MODULE__, :discover_and_register, 3}
      )

    case Client.discover(base_url, Keyword.fetch!(opts, :transport_opts)) do
      {:ok, agent_card} ->
        endpoint = derive_endpoint(base_url, agent_card)
        tools = from_agent_card(agent_card, endpoint, Keyword.delete(opts, :timeout))

        register_all(tools, registry, timeout: Keyword.fetch!(opts, :timeout))

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Creates `AgentTool` structs from a pre-fetched agent card.

  Returns one tool per skill, or a single general tool if no skills.

  ## Options

  #{Options.docs(@from_agent_card_opts_schema)}
  """
  @spec from_agent_card(Claudio.A2A.AgentCard.t(), String.t(), keyword()) :: [AgentTool.t()]
  def from_agent_card(agent_card, endpoint, opts \\ []) do
    tool_opts =
      Options.validate!(opts, @from_agent_card_opts_schema, {__MODULE__, :from_agent_card, 3})

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

  # A discovered name that is taken, or that the API would refuse, would otherwise
  # raise in Toolset.register/3; report it as this function's error instead.
  defp register_all(tools, registry, register_opts) do
    Enum.reduce_while(tools, {:ok, registry}, fn tool, {:ok, reg} ->
      case Toolset.register_new(reg, tool, register_opts) do
        {:ok, reg} -> {:cont, {:ok, reg}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
