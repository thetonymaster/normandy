defmodule AutoresumeDemo.Application do
  @moduledoc false
  use Application
  require Logger

  alias AutoresumeDemo.Topology
  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  @impl true
  def start(_type, _args) do
    role = Application.get_env(:autoresume_demo, :role, :standalone)

    Logger.info(
      "autoresume_demo starting role=#{role} mode=#{Application.get_env(:autoresume_demo, :demo_mode)}"
    )

    # Under :test the app starts NOTHING — each test starts exactly the infra it
    # needs (Repo via test_helper; Catalog/registry/supervisor via start_supervised),
    # which would otherwise collide with app-managed children (:already_started).
    children =
      case role do
        :test -> []
        _ -> common_children() ++ role_children(role)
      end

    {:ok, sup} =
      Supervisor.start_link(children, strategy: :one_for_one, name: AutoresumeDemo.Supervisor)

    # Populate the node-local Catalog now that it is running (not under :test).
    if role != :test, do: AutoresumeDemo.Agent.register_supplement(Topology.catalog())
    {:ok, sup}
  end

  # Registry member on EVERY node so the observer can do cluster-wide whereis.
  defp common_children do
    [
      AutoresumeDemo.Repo,
      %{id: Topology.catalog(), start: {Catalog, :start_link, [[name: Topology.catalog()]]}},
      %{id: Topology.registry(), start: {HReg, :start_link, [[name: Topology.registry()]]}}
    ]
  end

  defp role_children(:worker), do: worker_children()

  defp role_children(:observer) do
    # Observer-only components are added by their tasks (DemoCollector, Bandit,
    # ClusterLauncher). See Tasks 8-10. They are appended via observer_children/0.
    observer_children()
  end

  defp role_children(:standalone), do: worker_children() ++ standalone_extras()

  defp worker_children do
    [
      %{id: Topology.supervisor(), start: {HSup, :start_link, [[name: Topology.supervisor()]]}},
      %{
        id: ResumeReaper,
        start:
          {ResumeReaper, :start_link,
           [
             [
               store: Topology.store(),
               registry: Topology.registry_handle(),
               supervisor: Topology.supervisor(),
               supervisor_mod: HSup,
               template_provider: Topology.template_provider()
             ]
           ]}
      }
    ]
  end

  # Filled in by Tasks 9 & 10 (DemoCollector, Bandit, ClusterLauncher).
  defp observer_children, do: [AutoresumeDemo.DemoCollector]
  # DemoCollector so a single-node dev VM also has the dashboard.
  defp standalone_extras, do: [AutoresumeDemo.DemoCollector]
end
