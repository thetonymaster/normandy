defmodule Normandy.Application do
  @moduledoc false
  # Normandy's own processes: the keyed circuit breakers (Normandy.Resilience.CircuitBreaker)
  # and the registry :server-mode AgentProcesses share (AgentProcess.ScopedRegistry).
  # The two are independent, so the top level is :one_for_one. The breaker Registry and
  # DynamicSupervisor sit under their own :rest_for_one supervisor: a crashed breaker
  # Registry also stops every breaker (their registrations are gone; they are
  # `restart: :temporary`) and each starts again, closed, on its next call. That restart
  # never reaches the AgentProcess registry, so its registrations survive a breaker crash.
  #
  # A killed Registry supervisor leaves its partition processes (they trap exits) alive for
  # a moment, so an immediate restart fails with `{:already_started, partition_pid}` and,
  # retried at once, exhausts the supervisor's restart intensity. `start_registry/1`
  # waits (monitor, no sleep) for the named process that blocks the start to go down, then
  # starts again.
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
      registry_child(ScopedRegistry.registry_name())
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Normandy.Supervisor)
  end

  defp breaker_children do
    [
      registry_child(CircuitBreaker.Registry),
      {DynamicSupervisor, strategy: :one_for_one, name: CircuitBreaker.Supervisor}
    ]
  end

  defp registry_child(name) do
    %{
      id: name,
      type: :supervisor,
      start: {__MODULE__, :start_registry, [[keys: :unique, name: name]]}
    }
  end

  @doc false
  # Registry.start_link/1, retried (at most 5 times) once the process a failed start
  # reported as `{:already_started, pid}` is down.
  @spec start_registry(keyword(), non_neg_integer()) :: Supervisor.on_start()
  def start_registry(opts, retries \\ 5) do
    case Registry.start_link(opts) do
      {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, pid}}}}
      when retries > 0 ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> start_registry(opts, retries - 1)
        end

      other ->
        other
    end
  end
end
