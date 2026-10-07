defmodule Normandy.Coordination.AgentProcess.ScopedRegistry do
  @moduledoc false
  # The SessionRegistry a :server-mode AgentProcess uses when it is given none: one
  # unique Registry started by Normandy.Application (@registry), shared by every such
  # process, with a scope per process so two of them with the same agent id (and their
  # own stores) never see each other's servers. The handle is {@registry, scope}; keys
  # are {scope, session_id}. A Turn.Server registers itself, and its entry goes with it.
  # Starting one creates no atom (a Native registry per process created ~3).
  @behaviour Normandy.Behaviours.SessionRegistry

  @registry Normandy.Coordination.AgentProcess.Registry

  @doc false
  @spec registry_name() :: atom()
  def registry_name, do: @registry

  @doc false
  @spec new() :: {atom(), reference()}
  def new, do: {@registry, make_ref()}

  @impl true
  def whereis({registry, scope}, session_id) do
    case Registry.lookup(registry, {scope, session_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :none
    end
  end

  @impl true
  def register({registry, scope}, session_id, pid) when pid == self() do
    case Registry.register(registry, {scope, session_id}, nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :taken}
    end
  end

  @impl true
  def unregister({registry, scope}, session_id) do
    Registry.unregister(registry, {scope, session_id})
  end

  @impl true
  def child_name(_handle, _session_id), do: :self_register
end
