defmodule AutoresumeDemo.DemoCollectorResilienceTest do
  # async: false — touches the shared real store (the demo Repo) and starts the
  # singleton DemoCollector GenServer (registered name).
  use ExUnit.Case, async: false

  alias AutoresumeDemo.DemoCollector
  alias Normandy.Behaviours.SessionStore.Postgres, as: PG

  @store AutoresumeDemo.Repo

  defp cleanup_sessions(session_ids) do
    on_exit(fn ->
      for sid <- session_ids do
        @store.query!("DELETE FROM normandy_sessions WHERE session_id = $1", [sid])
      end
    end)
  end

  test "a poll cycle that raises (registry ETS table absent) does not crash the collector" do
    # Seed one eager, resumable session so the poll's list_resumable returns it and
    # the poll proceeds to call registry.whereis. Under :test the Horde registry name
    # (AutoresumeDemo.SessionRegistry) is NOT running, so Horde.Registry.lookup raises
    # ArgumentError (no ETS table) — exactly the transient mid-poll failure a node kill
    # produces. The collector must skip the cycle and stay alive.
    sid = "collector-resilience-#{System.unique_integer([:positive])}"
    cleanup_sessions([sid])

    :ok = PG.save_config_template(@store, sid, %{template_id: "research", resume_policy: :eager})

    :ok =
      PG.save_turn_state(@store, sid, %Normandy.Agents.Turn.State{
        status: :steering,
        iterations_left: 1
      })

    {:ok, pid} = DemoCollector.start_link(:ok)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    ref = Process.monitor(pid)

    # init/1 sends :poll immediately; force a few more synchronous poll cycles so the
    # raising path is definitely exercised, each time confirming we got a reply (proof
    # the process survived rather than terminating).
    for _ <- 1..3 do
      send(pid, :poll)
      assert is_map(DemoCollector.snapshot())
    end

    # The collector never terminated.
    refute_received {:DOWN, ^ref, :process, ^pid, _}
    assert Process.alive?(pid)
  end
end
