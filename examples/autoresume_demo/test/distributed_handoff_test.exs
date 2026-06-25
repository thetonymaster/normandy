defmodule AutoresumeDemo.DistributedHandoffTest do
  use ExUnit.Case, async: false
  @moduletag :distributed
  @moduletag timeout: 120_000

  alias AutoresumeDemo.{Agent, Topology}
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  setup do
    Application.put_env(:autoresume_demo, :demo_mode, :simulated)
    Application.put_env(:autoresume_demo, :sim_step_delay_ms, 2500)
    Application.put_env(:autoresume_demo, :worker_node_count, 2)
    :ok
  end

  test "killing the worker hosting a session resumes it on the survivor" do
    # The observer VM runs a registry member so whereis is cluster-wide.
    {:ok, _} =
      ensure_started(%{
        id: Topology.catalog(),
        start:
          {Normandy.Behaviours.AgentTemplate.Catalog, :start_link, [[name: Topology.catalog()]]}
      })

    {:ok, _} =
      ensure_started(%{
        id: Topology.registry(),
        start: {HReg, :start_link, [[name: Topology.registry()]]}
      })

    {:ok, _} = ensure_started(AutoresumeDemo.Repo)
    :ok = Agent.register_supplement(Topology.catalog())

    # The observer (this VM) decodes persisted Turn.State / ConfigTemplate blobs under
    # `[:safe]` (e.g. in `await_running_session`). Warm it so those decodes don't hit
    # not-yet-interned field atoms (the same trap the workers warm against at boot).
    :ok = Agent.warmup()

    {:ok, _} = AutoresumeDemo.ClusterLauncher.start_link(:ok)

    # Find a running session and the node it landed on.
    {store_mod, store_handle} = Topology.store()
    {sid, host_node} = await_running_session(store_mod, store_handle)

    # Kill that node.
    :ok = AutoresumeDemo.ClusterLauncher.kill(host_node)

    # Within seconds the reaper restarts the session on the OTHER worker.
    assert eventually(
             fn ->
               case HReg.whereis(Topology.registry(), sid) do
                 {:ok, pid} -> node(pid) != host_node
                 _ -> false
               end
             end,
             120
           ),
           "session #{sid} did not resume on a surviving node"

    # And it keeps making progress (iterations_left keeps decreasing or terminal).
    assert eventually(
             fn ->
               match?(
                 {:ok, %Turn.State{status: s}}
                 when s in [:steering, :assistant_streaming, :tool_dispatch, :stopped],
                 store_mod.load_turn_state(store_handle, sid)
               )
             end,
             120
           )
  end

  # Pick a session that the reaper can actually resume after a kill: it must be
  # eager, registered, AND already have a PERSISTED non-terminal turn state. A
  # session killed during its very first sim step (before any turn_state is written)
  # has nothing to resume from — `ResumeReaper.non_terminal?/3` skips it — so the
  # test must not select such a session or the handoff assertion is unwinnable.
  defp await_running_session(store_mod, store_handle) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      with {:ok, sids} <- store_mod.list_resumable(store_handle),
           sid when not is_nil(sid) <-
             Enum.find(sids, &resumable_now?(store_mod, store_handle, &1)),
           {:ok, pid} <- HReg.whereis(Topology.registry(), sid) do
        {:halt, {sid, node(pid)}}
      else
        _ ->
          Process.sleep(100)
          {:cont, nil}
      end
    end)
  end

  # Registered somewhere AND has a persisted, non-terminal turn state (mirrors the
  # reaper's resumability precondition).
  defp resumable_now?(store_mod, store_handle, sid) do
    match?({:ok, _}, HReg.whereis(Topology.registry(), sid)) and
      match?(
        {:ok, %Turn.State{status: s}} when s not in [:stopped, :failed],
        store_mod.load_turn_state(store_handle, sid)
      )
  end

  defp ensure_started(spec) do
    case start_supervised(spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp eventually(fun, tries) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.(),
        do: {:halt, true},
        else:
          (
            Process.sleep(200)
            {:cont, false}
          )
    end)
  end
end
