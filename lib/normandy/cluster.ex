defmodule Normandy.Cluster do
  @moduledoc """
  Optional convenience for wiring the distributed-session infra (Tier 2) into a
  host supervision tree. Returns child specs for:

    * the Horde **registry** (`SessionRegistry.Horde`, `members: :auto`),
    * the Horde **supervisor** (`Turn.Supervisor.Horde`, `members: :auto`),
    * the **`Turn.ResumeReaper`** (only when both `:store` and `:template_provider`
      are supplied — eager handoff needs them), and
    * an optional `libcluster` `Cluster.Supervisor` (only when `:topologies` is
      given AND `libcluster` is a dependency of the *host* app).

  Cluster formation remains the host's choice — this is sugar, not a requirement.
  Normandy does NOT depend on `libcluster`; the `Cluster.Supervisor` spec is added
  only if the running system has it loaded (a runtime check), so hosts that wire
  their own clustering (or none) are unaffected.

  ## Example (host `application.ex`)

      children = [
        MyApp.Repo,
        {Normandy.Behaviours.AgentTemplate.Catalog, name: MyApp.AgentTemplates}
      ] ++
        Normandy.Cluster.child_specs(
          registry: MyApp.SessionRegistry,
          supervisor: MyApp.TurnSupervisor,
          store: {Normandy.Behaviours.SessionStore.Postgres, MyApp.Repo},
          template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, MyApp.AgentTemplates},
          topologies: Application.get_env(:libcluster, :topologies, [])
        )

      Supervisor.start_link(children, strategy: :one_for_one)
  """
  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  @doc """
  Build the distributed-session child specs. Required: `:registry`, `:supervisor`
  (names/atoms). Optional: `:store` + `:template_provider` (enable the reaper),
  `:topologies` (enable libcluster if loaded).
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec() | :supervisor.child_spec() | map()]
  def child_specs(opts) do
    reg = Keyword.fetch!(opts, :registry)
    sup = Keyword.fetch!(opts, :supervisor)

    libcluster_specs(opts, reg) ++
      [
        %{id: reg, start: {HReg, :start_link, [[name: reg]]}},
        %{id: sup, start: {HSup, :start_link, [[name: sup]]}}
      ] ++
      reaper_specs(opts, reg, sup)
  end

  defp libcluster_specs(opts, reg) do
    topologies = Keyword.get(opts, :topologies, [])

    if topologies != [] and Code.ensure_loaded?(Cluster.Supervisor) do
      [{Cluster.Supervisor, [topologies, [name: Module.concat(reg, ClusterSupervisor)]]}]
    else
      []
    end
  end

  defp reaper_specs(opts, reg, sup) do
    store = Keyword.get(opts, :store)
    template_provider = Keyword.get(opts, :template_provider)

    if store && template_provider do
      [
        %{
          id: ResumeReaper,
          start:
            {ResumeReaper, :start_link,
             [
               [
                 store: store,
                 registry: {HReg, reg},
                 supervisor: sup,
                 supervisor_mod: HSup,
                 template_provider: template_provider
               ]
             ]}
        }
      ]
    else
      []
    end
  end
end
