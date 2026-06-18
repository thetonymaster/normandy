defmodule Normandy.Behaviours.AgentTemplate do
  @moduledoc """
  Resolves the **node-local, non-serializable** half of an agent's config from a
  stable `template_id`: the tool registry, before/after hooks, and a
  `client_builder` that turns a credential token into an LLM client struct.

  The host registers a supplement per `template_id` on **every node** at boot
  (same code → same supplement). Combined with the persisted non-secret template
  (`SessionStore.{save,load}_config_template`) and the node-local
  `CredentialProvider`, this reconstructs a full `%BaseAgentConfig{}` on any node
  without moving secrets or closures across the cluster.
  """

  @type supplement :: %{
          tool_registry: term(),
          before_hooks: [term()],
          after_hooks: [term()],
          client_builder: (String.t() -> struct())
        }

  @callback fetch(handle :: term(), template_id :: String.t()) :: {:ok, supplement()} | :error

  defmodule Catalog do
    @moduledoc "Default node-local `AgentTemplate`: an Agent mapping template_id → supplement."
    @behaviour Normandy.Behaviours.AgentTemplate

    use Agent

    @spec start_link(keyword()) :: Agent.on_start()
    def start_link(opts) do
      name = Keyword.get(opts, :name)
      init = Keyword.get(opts, :templates, %{})
      if name, do: Agent.start_link(fn -> init end, name: name), else: Agent.start_link(fn -> init end)
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
