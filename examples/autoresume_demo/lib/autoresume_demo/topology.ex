defmodule AutoresumeDemo.Topology do
  @moduledoc "Shared process names and behaviour handles used on every node."

  @registry AutoresumeDemo.SessionRegistry
  @supervisor AutoresumeDemo.TurnSupervisor
  @catalog AutoresumeDemo.AgentTemplates

  def registry, do: @registry
  def supervisor, do: @supervisor
  def catalog, do: @catalog

  def store, do: {Normandy.Behaviours.SessionStore.Postgres, AutoresumeDemo.Repo}
  def registry_handle, do: {Normandy.Behaviours.SessionRegistry.Horde, @registry}
  def template_provider, do: {Normandy.Behaviours.AgentTemplate.Catalog, @catalog}
end
