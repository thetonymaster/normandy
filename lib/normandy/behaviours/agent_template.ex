defmodule Normandy.Behaviours.AgentTemplate do
  @moduledoc """
  Resolves the **node-local, non-serializable** half of an agent's config from a
  stable `template_id`: the toolset, before/after hooks, and a
  `client_builder` that turns a credential token into an LLM client struct.
  Optionally `:mcp_servers` (which may carry authorization tokens);
  `ConfigTemplate.rebuild/3` requires it when the original config had it set.
  Optionally `:pinned`: the security settings this node fixes for the template,
  `[policy: ref, guardrails: list, credential: ref, ...]`. A stored template whose value
  differs is refused (see `Normandy.Agents.ConfigTemplate`'s "Trust boundary").

  The host registers a supplement per `template_id` on **every node** at boot
  (same code → same supplement). Combined with the persisted non-secret template
  (`SessionStore.{save,load}_config_template`) and the node-local
  `CredentialProvider`, this reconstructs a full `%BaseAgentConfig{}` on any node
  without moving secrets or closures across the cluster.
  """

  @type supplement :: %{
          required(:toolset) => Normandy.Tools.Toolset.t() | nil,
          required(:before_hooks) => [term()],
          required(:after_hooks) => [term()],
          required(:client_builder) => (String.t() -> struct()),
          optional(:mcp_servers) => [term()],
          optional(:pinned) => keyword()
        }

  @callback fetch(handle :: term(), template_id :: String.t()) :: {:ok, supplement()} | :error

  defmodule Catalog do
    @moduledoc "Default node-local `AgentTemplate`: an Agent mapping template_id → supplement."
    @behaviour Normandy.Behaviours.AgentTemplate

    use Agent

    alias Normandy.Options

    @start_link_opts_schema NimbleOptions.new!(
                              name: [type: :any, doc: "A `t:GenServer.name/0` for the catalog."],
                              templates: [
                                type: {:custom, Normandy.Options, :plain_map, []},
                                type_doc: "`t:map/0`",
                                default: %{},
                                doc: "The initial `template_id => supplement` map."
                              ]
                            )

    @doc """
    Starts the catalog.

    ## Options

    #{Options.docs(@start_link_opts_schema)}
    """
    @spec start_link(keyword()) :: Agent.on_start()
    def start_link(opts) do
      opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})
      name = Keyword.get(opts, :name)
      init = Keyword.fetch!(opts, :templates)

      if name,
        do: Agent.start_link(fn -> init end, name: name),
        else: Agent.start_link(fn -> init end)
    end

    @spec put(Agent.agent(), String.t(), Normandy.Behaviours.AgentTemplate.supplement()) :: :ok
    def put(cat, template_id, supplement),
      do: Agent.update(cat, &Map.put(&1, template_id, supplement))

    @impl true
    def fetch(cat, template_id) do
      case Agent.get(cat, &Map.get(&1, template_id)) do
        nil -> :error
        supp -> {:ok, supp}
      end
    end
  end
end
