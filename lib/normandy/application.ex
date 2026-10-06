defmodule Normandy.Application do
  @moduledoc false
  # Normandy's own processes: the keyed circuit breakers (Normandy.Resilience.CircuitBreaker).
  # :rest_for_one, so breakers registered in a crashed Registry are restarted with it.
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Normandy.Resilience.CircuitBreaker.Registry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Normandy.Resilience.CircuitBreaker.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Normandy.Supervisor)
  end
end
