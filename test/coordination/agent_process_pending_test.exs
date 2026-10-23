defmodule Normandy.Coordination.AgentProcessPendingTest do
  @moduledoc """
  Task 6.5d (SEC-14): casts go through the same admission as runs. Inline casts are
  queued and keep their memory; `:max_pending_runs` bounds runs and casts in both
  modes; every worker dies with its process.

  LLM calls are gated as in `AgentProcessQueueTest`: `{:llm_started, n, worker}`, then
  `{:release, n}` to that worker.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  # How long a gate event may take to arrive. A turn's worker reaches the client after
  # BaseAgent's setup, which under a loaded suite (async DSL tests compiling modules)
  # has taken over ExUnit's default 100 ms; the events always come, so wait for them.
  @wait 5_000

  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.PromptSpecification
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Test.StubClient
  alias Normandy.TurnError

  defp gate do
    parent = self()
    calls = :atomics.new(1, [])

    fn ->
      n = :atomics.add_get(calls, 1, 1)
      send(parent, {:llm_started, n, self()})

      receive do
        {:release, ^n} -> n
      end
    end
  end

  defp gated_agent do
    wait = gate()

    BaseAgent.init(%{
      client: %StubClient{reply: fn rm -> %{rm | chat_message: "answer #{wait.()}"} end},
      model: "m"
    })
  end

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Memory encodes every entry when it is appended (Task 6.1a): the output needs an impl.
  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # A :server-mode template whose LLM call is gated (the Turn.Server worker runs it).
  defp gated_server_start(extra) do
    wait = gate()

    config = %BaseAgentConfig{
      output_schema: %Resp{},
      model: "test",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %PromptSpecification{}
    }

    handlers = %{
      AgentHandlers.non_streaming_handlers()
      | call_llm: fn _c, _s, _r -> %Resp{content: "answer #{wait.()}"} end
    }

    AgentProcess.start_link([agent: config, turn_engine: :server, handlers: handlers] ++ extra)
  end

  describe "inline cast/3" do
    test "is queued behind runs and keeps its turn in memory" do
      {:ok, pid} = AgentProcess.start_link(agent: gated_agent(), agent_id: "c")
      run = Task.async(fn -> AgentProcess.run(pid, "one") end)
      assert_receive {:llm_started, 1, worker1}, @wait

      :ok = AgentProcess.cast(pid, "two", reply_to: self())
      refute_received {:llm_started, 2, _}

      send(worker1, {:release, 1})
      assert {:ok, "answer 1"} = Task.await(run)

      assert_receive {:llm_started, 2, worker2}, @wait
      send(worker2, {:release, 2})
      assert_receive {:agent_result, "c", {:ok, "answer 2"}}, @wait

      assert AgentMemory.count_messages(AgentProcess.get_agent(pid).memory) == 4
      assert %{run_count: 2} = AgentProcess.get_stats(pid)
    end

    test "an exit in the cast's turn still reaches reply_to" do
      agent =
        BaseAgent.init(%{client: %StubClient{reply: fn _ -> exit(:gone) end}, model: "m"})

      {:ok, pid} = AgentProcess.start_link(agent: agent, agent_id: "c_exit")
      :ok = AgentProcess.cast(pid, "go", reply_to: self())

      assert_receive {:agent_result, "c_exit",
                      {:error, %TurnError{type: :task_down, reason: :gone}}},
                     @wait
    end

    test "a reply_to name that is not registered does not stop the process" do
      {:ok, pid} =
        AgentProcess.start_link(agent: BaseAgent.init(%{client: %StubClient{}, model: "m"}))

      :ok = AgentProcess.cast(pid, "go", reply_to: :normandy_no_such_process)
      assert {:ok, _} = AgentProcess.run(pid, "after")
      assert %{run_count: 2} = AgentProcess.get_stats(pid)
    end

    # Final review I4: a raw {:run_async, ...} cast (an older node, or code bypassing
    # cast/3) can carry a reply_to cast/3 refuses; notify/3 must not crash on it.
    test "a raw cast whose reply_to is neither a pid nor an atom does not stop the process" do
      {:ok, pid} =
        AgentProcess.start_link(
          agent: BaseAgent.init(%{client: %StubClient{}, model: "m"}),
          agent_id: "raw"
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          GenServer.cast(pid, {:run_async, "go", {:normandy_remote_name, :nonode@nowhere}})
          assert {:ok, _} = AgentProcess.run(pid, "after")
        end)

      assert Process.alive?(pid)
      assert %{run_count: 2} = AgentProcess.get_stats(pid)
      assert log =~ "AgentProcess raw: reply_to is a tuple, not a pid or a registered name"
      refute log =~ "normandy_remote_name"
    end

    test "a raw cast refused :queue_full with an unusable reply_to does not stop the process" do
      {:ok, pid} =
        AgentProcess.start_link(agent: gated_agent(), agent_id: "raw_full", max_pending_runs: 1)

      run = Task.async(fn -> AgentProcess.run(pid, "one") end)
      assert_receive {:llm_started, 1, worker}, @wait

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          GenServer.cast(pid, {:run_async, "two", {:via, Registry, {:normandy_x, 1}}, nil})
          assert %{pending: 1} = :sys.get_state(pid)
        end)

      assert log =~ "reply_to is a tuple"
      send(worker, {:release, 1})
      assert {:ok, "answer 1"} = Task.await(run)
      assert Process.alive?(pid)
    end

    test "stop/1 kills the cast in flight" do
      {:ok, pid} = AgentProcess.start_link(agent: gated_agent())
      :ok = AgentProcess.cast(pid, "go")
      assert_receive {:llm_started, 1, worker}, @wait
      ref = Process.monitor(worker)

      :ok = AgentProcess.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @wait
    end
  end

  describe ":max_pending_runs" do
    test "inline: the run or cast past the limit is refused at once, the others complete" do
      {:ok, pid} =
        AgentProcess.start_link(agent: gated_agent(), agent_id: "b", max_pending_runs: 2)

      :ok = AgentProcess.cast(pid, "one", reply_to: self())
      assert_receive {:llm_started, 1, worker1}, @wait
      :ok = AgentProcess.cast(pid, "two", reply_to: self())

      :ok = AgentProcess.cast(pid, "three", reply_to: self())

      assert_receive {:agent_result, "b",
                      {:error, %TurnError{type: :queue_full, reason: 2} = refused}},
                     @wait

      assert Exception.message(refused) == "turn refused: queue full: 2 run(s) already pending"

      assert {:error, %TurnError{type: :queue_full, reason: 2}} = AgentProcess.run(pid, "four")

      send(worker1, {:release, 1})
      assert_receive {:agent_result, "b", {:ok, "answer 1"}}, @wait
      assert_receive {:llm_started, 2, worker2}, @wait
      send(worker2, {:release, 2})
      assert_receive {:agent_result, "b", {:ok, "answer 2"}}, @wait

      # Room again once they finished.
      task = Task.async(fn -> AgentProcess.run(pid, "five") end)
      assert_receive {:llm_started, 3, worker3}, @wait
      send(worker3, {:release, 3})
      assert {:ok, "answer 3"} = Task.await(task)
      assert %{run_count: 3} = AgentProcess.get_stats(pid)
    end

    test "Review Focus 4: a long run, reads during it, 100 casts at the default limit, a dead caller" do
      {:ok, pid} = AgentProcess.start_link(agent: gated_agent(), agent_id: "rf4")
      caller = spawn(fn -> AgentProcess.run(pid, "long") end)
      assert_receive {:llm_started, 1, worker1}, @wait

      assert %{run_count: 0} = AgentProcess.get_stats(pid)
      assert AgentMemory.count_messages(AgentProcess.get_agent(pid).memory) == 0

      # The run in flight is 1 of the default 100: casts 1..99 are admitted, cast 100 is not.
      for i <- 1..100, do: :ok = AgentProcess.cast(pid, "cast #{i}", reply_to: self())

      assert_receive {:agent_result, "rf4", {:error, %TurnError{type: :queue_full, reason: 100}}},
                     @wait

      # The caller dies mid-run; its turn still finishes and is kept.
      caller_ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @wait

      worker_ref = Process.monitor(worker1)
      send(worker1, {:release, 1})
      assert_receive {:DOWN, ^worker_ref, :process, ^worker1, _reason}, @wait

      for n <- 2..100 do
        assert_receive {:llm_started, ^n, worker}, @wait
        send(worker, {:release, n})
        expected = "answer #{n}"
        assert_receive {:agent_result, "rf4", {:ok, ^expected}}, @wait
      end

      refute_received {:agent_result, "rf4", {:error, _}}
      assert AgentMemory.count_messages(AgentProcess.get_agent(pid).memory) == 200
      assert %{run_count: 100} = AgentProcess.get_stats(pid)
      assert %{running: nil, pending: 0} = :sys.get_state(pid)
    end

    test "update_agent/2 is not a pending run" do
      {:ok, pid} = AgentProcess.start_link(agent: gated_agent(), max_pending_runs: 1)
      run = Task.async(fn -> AgentProcess.run(pid, "one") end)
      assert_receive {:llm_started, 1, worker1}, @wait

      update = Task.async(fn -> AgentProcess.update_agent(pid, &%{&1 | temperature: 0.1}) end)
      assert {:error, %TurnError{type: :queue_full}} = AgentProcess.run(pid, "two")

      send(worker1, {:release, 1})
      assert {:ok, "answer 1"} = Task.await(run)
      assert :ok = Task.await(update)
    end

    test ":server: the run or cast past the limit is refused at once" do
      {:ok, pid} = gated_server_start(agent_id: "s", max_pending_runs: 1)
      run = Task.async(fn -> AgentProcess.run(pid, "one") end)
      assert_receive {:llm_started, 1, worker}, @wait

      assert {:error, %TurnError{type: :queue_full, reason: 1}} = AgentProcess.run(pid, "two")
      :ok = AgentProcess.cast(pid, "three", reply_to: self())
      assert_receive {:agent_result, "s", {:error, %TurnError{type: :queue_full}}}, @wait

      send(worker, {:release, 1})
      assert {:ok, %Resp{content: "answer 1"}} = Task.await(run)
    end

    test "is validated by start_link/1" do
      agent = BaseAgent.init(%{client: %StubClient{}, model: "m"})

      error =
        assert_raise ArgumentError, fn ->
          AgentProcess.start_link(agent: agent, max_pending_runs: 0)
        end

      assert error.message =~
               "Normandy.Coordination.AgentProcess.start_link/1: expected :max_pending_runs " <>
                 "option to match at least one given type"

      assert error.message =~ "expected positive integer, got: 0"

      assert {:ok, _pid} = AgentProcess.start_link(agent: agent, max_pending_runs: :infinity)
    end
  end

  # Final review I3: the state holds the agent (memory, client) and every queued input.
  describe "format_status" do
    @secret "a secret the user typed"

    test "inline: :sys.get_status/1 shows counters, never memory or queued inputs" do
      {:ok, pid} = AgentProcess.start_link(agent: gated_agent(), agent_id: "st")
      first = Task.async(fn -> AgentProcess.run(pid, @secret) end)
      assert_receive {:llm_started, 1, worker1}, @wait
      send(worker1, {:release, 1})
      assert {:ok, "answer 1"} = Task.await(first)

      second = Task.async(fn -> AgentProcess.run(pid, "busy") end)
      assert_receive {:llm_started, 2, worker2}, @wait
      :ok = AgentProcess.cast(pid, @secret)
      queued = Task.async(fn -> AgentProcess.run(pid, @secret) end)

      assert wait_until(fn ->
               :queue.len(:sys.get_state(pid).queue) == 2
             end)

      status = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)
      assert status =~ ~s(agent_id: "st")
      assert status =~ "queued: 2"
      refute status =~ @secret
      refute status =~ "BaseAgentConfig"

      send(worker2, {:release, 2})
      assert {:ok, "answer 2"} = Task.await(second)

      for n <- 3..4 do
        assert_receive {:llm_started, ^n, worker}, @wait
        send(worker, {:release, n})
      end

      assert {:ok, _} = Task.await(queued)
    end

    test ":server: :sys.get_status/1 never shows a pending run's input" do
      {:ok, pid} = gated_server_start(agent_id: "st_srv")
      :ok = AgentProcess.cast(pid, @secret)
      assert_receive {:llm_started, 1, worker}, @wait

      status = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)
      assert status =~ "in_flight: 1"
      refute status =~ @secret
      refute status =~ "BaseAgentConfig"
      send(worker, {:release, 1})
    end

    test "a crash's last message is its request tag only" do
      status =
        AgentProcess.format_status(%{
          message: {:"$gen_call", {self(), make_ref()}, {:run, @secret, nil}}
        })

      assert status.message == {:"$gen_call", :run}

      status =
        AgentProcess.format_status(%{message: {:"$gen_cast", {:run_async, @secret, nil, nil}}})

      assert status.message == {:"$gen_cast", :run_async}
    end
  end

  describe ":server workers" do
    test "stop/1 kills a cast's worker" do
      {:ok, pid} = gated_server_start([])
      :ok = AgentProcess.cast(pid, "go")
      assert_receive {:llm_started, 1, _turn_worker}, @wait

      %{pending_runs: pending} = :sys.get_state(pid)
      assert [watcher] = Map.keys(pending)
      ref = Process.monitor(watcher)

      :ok = AgentProcess.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^watcher, _reason}, @wait
    end
  end
end
