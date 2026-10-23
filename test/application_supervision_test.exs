defmodule Normandy.ApplicationSupervisionTest do
  # async: false — kills named processes of the application's supervision tree.
  use ExUnit.Case, async: false

  alias Normandy.Coordination.AgentProcess.ScopedRegistry
  alias Normandy.Resilience.CircuitBreaker

  defp await_new_pid(name, old_pid, tries \\ 100) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when tries > 0 ->
        Process.sleep(10)
        await_new_pid(name, old_pid, tries - 1)

      other ->
        flunk("#{inspect(name)} did not restart; whereis is #{inspect(other)}")
    end
  end

  test "a breaker Registry crash keeps the AgentProcess ScopedRegistry registrations" do
    handle = ScopedRegistry.new()
    session_id = "sess-#{System.unique_integer([:positive])}"
    test_pid = self()

    holder =
      start_supervised!(
        {Task,
         fn ->
           :ok = ScopedRegistry.register(handle, session_id, self())
           send(test_pid, :registered)
           Process.sleep(:infinity)
         end}
      )

    assert_receive :registered
    assert ScopedRegistry.whereis(handle, session_id) == {:ok, holder}

    app_supervisor = Process.whereis(Normandy.Supervisor)
    breaker_registry = Process.whereis(CircuitBreaker.Registry)
    Process.exit(breaker_registry, :kill)
    await_new_pid(CircuitBreaker.Registry, breaker_registry)
    await_new_pid(CircuitBreaker.Supervisor, nil)

    assert ScopedRegistry.whereis(handle, session_id) == {:ok, holder}
    assert Process.whereis(Normandy.Supervisor) == app_supervisor
    assert List.keymember?(Application.started_applications(), :normandy, 0)
  end
end
