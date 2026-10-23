defmodule Normandy.Coordination.AgentProcessQueueTest do
  @moduledoc """
  Task 6.5c (A7, PERF-13): an inline `AgentProcess` runs its turns one at a time from a
  FIFO queue in a watched worker, so reads answer during a turn, runs and
  `update_agent/2` keep their order and memory, and a turn dies with its process.

  Every LLM call is gated: the client sends `{:llm_started, n, worker}` from the worker
  and blocks until the test sends `{:release, n}` to that worker.
  """
  use ExUnit.Case, async: true

  # How long a gate event may take to arrive. A turn's worker reaches the client after
  # BaseAgent's setup, which under a loaded suite (async DSL tests compiling modules)
  # has taken over ExUnit's default 100 ms; the events always come, so wait for them.
  @wait 5_000

  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.AgentMemory
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Test.StubClient
  alias Normandy.TurnError

  defp gated_agent do
    parent = self()
    calls = :atomics.new(1, [])

    reply = fn response_model ->
      n = :atomics.add_get(calls, 1, 1)
      send(parent, {:llm_started, n, self()})

      receive do
        {:release, ^n} -> %{response_model | chat_message: "answer #{n}"}
      end
    end

    BaseAgent.init(%{client: %StubClient{reply: reply}, model: "m"})
  end

  defp run_in_task(pid, input), do: Task.async(fn -> AgentProcess.run(pid, input) end)

  defp queued(pid), do: :queue.len(:sys.get_state(pid).engine_state.queue)

  defp messages(pid), do: AgentMemory.count_messages(AgentProcess.get_agent(pid).memory)

  test "reads answer at once while a turn runs" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent(), agent_id: "busy")
    task = run_in_task(pid, "go")
    assert_receive {:llm_started, 1, worker}, @wait

    # A blocking implementation exits each of these with {:timeout, _} after 5 s.
    assert %{agent_id: "busy", run_count: 0} = AgentProcess.get_stats(pid)
    assert AgentProcess.get_id(pid) == "busy"
    assert messages(pid) == 0
    assert AgentProcess.approve(pid, %{}) == {:error, :inline_mode}

    send(worker, {:release, 1})
    assert {:ok, "answer 1"} = Task.await(task)
    assert %{run_count: 1} = AgentProcess.get_stats(pid)
    assert messages(pid) == 2
  end

  test "runs execute one at a time, in order, each from the memory the previous one left" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    first = run_in_task(pid, "one")
    assert_receive {:llm_started, 1, worker1}, @wait

    second = run_in_task(pid, "two")
    assert wait_until(fn -> queued(pid) == 1 end)
    refute_received {:llm_started, 2, _}

    send(worker1, {:release, 1})
    assert {:ok, "answer 1"} = Task.await(first)

    assert_receive {:llm_started, 2, worker2}, @wait
    send(worker2, {:release, 2})
    assert {:ok, "answer 2"} = Task.await(second)

    assert messages(pid) == 4
    assert %{run_count: 2} = AgentProcess.get_stats(pid)
  end

  test "update_agent/2 waits for the turn in flight and the next run sees both" do
    parent = self()
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    first = run_in_task(pid, "one")
    assert_receive {:llm_started, 1, worker1}, @wait

    update =
      Task.async(fn ->
        AgentProcess.update_agent(pid, fn agent ->
          send(parent, {:update_saw, AgentMemory.count_messages(agent.memory)})
          %{agent | temperature: 0.3}
        end)
      end)

    assert wait_until(fn -> queued(pid) == 1 end)
    assert Task.yield(update, 0) == nil

    send(worker1, {:release, 1})
    assert {:ok, "answer 1"} = Task.await(first)
    assert :ok = Task.await(update)
    assert_received {:update_saw, 2}

    second = run_in_task(pid, "two")
    assert_receive {:llm_started, 2, worker2}, @wait
    send(worker2, {:release, 2})
    assert {:ok, "answer 2"} = Task.await(second)

    agent = AgentProcess.get_agent(pid)
    assert agent.temperature == 0.3
    assert AgentMemory.count_messages(agent.memory) == 4
  end

  test "a queued run whose caller died is skipped" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    first = run_in_task(pid, "one")
    assert_receive {:llm_started, 1, worker1}, @wait

    doomed = spawn(fn -> AgentProcess.run(pid, "never") end)
    assert wait_until(fn -> queued(pid) == 1 end)
    ref = Process.monitor(doomed)
    Process.exit(doomed, :kill)
    assert_receive {:DOWN, ^ref, :process, ^doomed, :killed}, @wait

    third = run_in_task(pid, "three")
    assert wait_until(fn -> queued(pid) == 2 end)

    send(worker1, {:release, 1})
    assert {:ok, "answer 1"} = Task.await(first)

    # The dead caller's run never reached the client: the next call is the third run's.
    assert_receive {:llm_started, 2, worker3}, @wait
    send(worker3, {:release, 2})
    assert {:ok, "answer 2"} = Task.await(third)

    assert %{run_count: 2} = AgentProcess.get_stats(pid)
    assert messages(pid) == 4
    # The skipped run gave back its admission: a leak here refuses every run :queue_full
    # once :max_pending_runs callers have died.
    assert %{pending: 0} = :sys.get_state(pid)
  end

  # Final review I1: a turn runs in a WatchedWorker grandchild. Its `$callers` chain must
  # lead back to the AgentProcess, as a Task's does, or a host's `Mox.allow/3` or
  # `Req.Test.allow/3` to the agent pid no longer reaches the LLM call.
  test "a run's and a cast's LLM call see the AgentProcess in their $callers" do
    parent = self()

    reply = fn response_model ->
      send(parent, {:callers, Process.get(:"$callers")})
      %{response_model | chat_message: "ok"}
    end

    agent = BaseAgent.init(%{client: %StubClient{reply: reply}, model: "m"})
    {:ok, pid} = AgentProcess.start_link(agent: agent)

    assert {:ok, "ok"} = AgentProcess.run(pid, "go")
    assert_receive {:callers, [_watcher, ^pid | _]}, @wait

    :ok = AgentProcess.cast(pid, "go", reply_to: self())
    assert_receive {:callers, [_watcher, ^pid | _]}, @wait
    assert_receive {:agent_result, _id, {:ok, "ok"}}, @wait
  end

  test "stop/1 kills the turn in flight" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    _caller = spawn(fn -> AgentProcess.run(pid, "go") end)
    assert_receive {:llm_started, 1, worker}, @wait
    ref = Process.monitor(worker)

    :ok = AgentProcess.stop(pid)

    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @wait
  end

  test "a worker killed from outside replies a :task_down TurnError and the next run works" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    first = run_in_task(pid, "one")
    assert_receive {:llm_started, 1, worker1}, @wait

    Process.exit(worker1, :kill)

    assert {:error, %TurnError{type: :task_down, reason: :killed}} = Task.await(first)
    assert Process.alive?(pid)
    assert messages(pid) == 0

    second = run_in_task(pid, "two")
    assert_receive {:llm_started, 2, worker2}, @wait
    send(worker2, {:release, 2})
    assert {:ok, "answer 2"} = Task.await(second)
  end

  test "an exit or a throw in the turn replies a :task_down TurnError and is logged" do
    for {kind, client_reply, reason} <- [
          {:exit, fn _rm -> exit(:client_gone) end, :client_gone},
          {:throw, fn _rm -> throw(:client_threw) end, {:nocatch, :client_threw}}
        ] do
      agent = BaseAgent.init(%{client: %StubClient{reply: client_reply}, model: "m"})
      {:ok, pid} = AgentProcess.start_link(agent: agent, agent_id: "k_#{kind}")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %TurnError{type: :task_down, reason: ^reason}} =
                   AgentProcess.run(pid, "go")
        end)

      assert log =~ "Agent k_#{kind} raised #{kind}"
      assert Process.alive?(pid)
    end
  end

  test "run/3 waits without a timeout by default" do
    assert AgentProcess.__opts_schema__(:run).schema[:timeout][:default] == :infinity
  end

  # Fix round 1 (I1): update_agent/2 is queued behind the turn in flight, so it must not
  # use GenServer.call's 5 s default. The refute_receive outlasts that default: with it, the
  # caller exits {:timeout, _} at 5 s, before the window ends. The run stays held by its gate
  # for the whole window, so the result does not depend on timing.
  @tag timeout: 30_000
  test "update_agent/2 waits past 5 s for a turn in flight, then applies after its memory" do
    parent = self()
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    first = run_in_task(pid, "one")
    assert_receive {:llm_started, 1, worker1}, @wait

    update =
      Task.async(fn ->
        AgentProcess.update_agent(pid, fn agent ->
          send(parent, {:update_saw, AgentMemory.count_messages(agent.memory)})
          %{agent | temperature: 0.7}
        end)
      end)

    update_ref = Process.monitor(update.pid)
    assert wait_until(fn -> queued(pid) == 1 end)
    refute_receive {:DOWN, ^update_ref, :process, _, _}, 5_500
    refute_received {:update_saw, _}

    send(worker1, {:release, 1})
    assert {:ok, "answer 1"} = Task.await(first)
    assert :ok = Task.await(update)
    assert_received {:update_saw, 2}

    agent = AgentProcess.get_agent(pid)
    assert agent.temperature == 0.7
    assert AgentMemory.count_messages(agent.memory) == 2
  end

  test "update_agent/3 bounds the wait with :timeout; the queued update still applies" do
    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
    first = run_in_task(pid, "one")
    assert_receive {:llm_started, 1, worker1}, @wait

    assert {:timeout, _} =
             catch_exit(AgentProcess.update_agent(pid, &%{&1 | temperature: 0.4}, timeout: 50))

    send(worker1, {:release, 1})
    assert {:ok, "answer 1"} = Task.await(first)
    assert AgentProcess.get_agent(pid).temperature == 0.4
  end

  test "update_agent/3 waits without a timeout by default and validates its options" do
    assert AgentProcess.__opts_schema__(:update_agent).schema[:timeout][:default] == :infinity

    {:ok, pid} = AgentProcess.start_link(agent: gated_agent())

    assert_raise ArgumentError, ~r/^Normandy.Coordination.AgentProcess.update_agent\/3: /, fn ->
      AgentProcess.update_agent(pid, & &1, bogus: 1)
    end
  end
end
