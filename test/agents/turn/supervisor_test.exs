defmodule Normandy.Agents.Turn.SupervisorTest do
  use ExUnit.Case, async: true
  import Normandy.Test.Eventually

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.TurnConfig

  @moduletag :capture_log

  defp start_sessions(sup, count) do
    store = InMemory.new()
    reg = Native.new()

    for n <- 1..count do
      {:ok, pid} =
        Turn.Supervisor.start_server(sup,
          session_id: "s#{n}",
          config: TurnConfig.build(),
          store: {InMemory, store},
          registry: {Native, reg}
        )

      pid
    end
  end

  # Kill each server once, waiting for its restart before the next kill, so
  # every kill counts as one restart against the supervisor's limit.
  defp crash_each(sup, pids) do
    Enum.each(pids, fn pid ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      wait_until(fn -> stopped_or_full?(sup, length(pids)) end)
    end)
  end

  defp child_count(sup), do: DynamicSupervisor.count_children(sup).active

  # The supervisor may stop between any two calls, so a call exit counts as stopped.
  defp stopped_or_full?(sup, count) do
    child_count(sup) == count
  catch
    :exit, _ -> true
  end

  test "the default limit absorbs many unrelated session crashes" do
    {:ok, sup} = Turn.Supervisor.start_link([])

    crash_each(sup, start_sessions(sup, 10))

    assert Process.alive?(sup)
    assert child_count(sup) == 10
  end

  test ":max_restarts and :max_seconds set the limit" do
    Process.flag(:trap_exit, true)
    {:ok, sup} = Turn.Supervisor.start_link(max_restarts: 1, max_seconds: 60)

    crash_each(sup, start_sessions(sup, 2))

    assert_receive {:EXIT, ^sup, :shutdown}
  end
end
