defmodule Normandy.Application do
  @moduledoc false
  # Normandy's own processes: the keyed circuit breakers (Normandy.Resilience.CircuitBreaker)
  # and the registry :server-mode AgentProcesses share (AgentProcess.ScopedRegistry).
  # The two are independent, so the top level is :one_for_one. The breaker Registry and
  # DynamicSupervisor sit under their own :rest_for_one supervisor: a crashed breaker
  # Registry also stops every breaker (their registrations are gone; they are
  # `restart: :temporary`) and each starts again, closed, on its next call. That restart
  # never reaches the AgentProcess registry, so its registrations survive a breaker crash.
  use Application

  alias Normandy.Coordination.AgentProcess.ScopedRegistry
  alias Normandy.Resilience.CircuitBreaker

  @impl true
  def start(_type, _args) do
    children = [
      %{
        id: CircuitBreaker.Group,
        type: :supervisor,
        start: {Supervisor, :start_link, [breaker_children(), [strategy: :rest_for_one]]}
      },
      {Registry, keys: :unique, name: ScopedRegistry.registry_name()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Normandy.Supervisor)
  end

  defp breaker_children do
    [
      {Registry, keys: :unique, name: CircuitBreaker.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: CircuitBreaker.Supervisor}
    ]
  end
end
