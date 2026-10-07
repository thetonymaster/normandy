defmodule Normandy.Application do
  @moduledoc false
  # Normandy's own processes: the keyed circuit breakers (Normandy.Resilience.CircuitBreaker)
  # and the registry :server-mode AgentProcesses share (AgentProcess.ScopedRegistry).
  # :rest_for_one, so a crashed breaker Registry also stops every breaker (their
  # registrations are gone; they are `restart: :temporary`). Each starts again, closed, on
  # its next call. The AgentProcess registry is last: its crash stops nothing else.
  use Application

  alias Normandy.Coordination.AgentProcess.ScopedRegistry

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Normandy.Resilience.CircuitBreaker.Registry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Normandy.Resilience.CircuitBreaker.Supervisor},
      {Registry, keys: :unique, name: ScopedRegistry.registry_name()}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Normandy.Supervisor)
  end
end
