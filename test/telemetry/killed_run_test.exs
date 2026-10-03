defmodule NormandyTest.Telemetry.KilledRunTest do
  @moduledoc """
  A coordinator that kills a task mid-`BaseAgent.run` (a race loser, an
  `on_timeout: :kill_task` expiry) emits a synthetic
  `[:normandy, :agent, :run, :exception]` with `reason: :killed` for it.

  The assertions use a plain `:telemetry` handler, filtered by a per-test agent
  name: handlers are global, and other tests emit run events concurrently.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Batch.Processor
  alias Normandy.Coordination.{AgentProcess, ParallelOrchestrator, Reactive}
  alias Normandy.Test.StubClient

  @exception [:normandy, :agent, :run, :exception]

  setup do
    name = "killed-run-#{System.unique_integer([:positive])}"
    handler_id = {__MODULE__, name}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @exception,
        fn _event, measurements, metadata, _config ->
          if metadata.agent_name == name do
            send(test_pid, {:run_exception, measurements, metadata, current_span_ctx()})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{name: name}
  end

  defp current_span_ctx, do: OpenTelemetry.Tracer.current_span_ctx()

  # A run that never finishes: its LLM call blocks until the task is killed.
  defp stuck_agent(name) do
    agent = BaseAgent.init(%{client: %StubClient{reply: &block/1}, model: "stuck-model"})
    %{agent | name: name}
  end

  defp block(_response_model) do
    receive do
      :never -> :ok
    end
  end

  defp wait_until(fun) do
    if fun.() do
      :ok
    else
      Process.sleep(1)
      wait_until(fun)
    end
  end

  defp fast_agent(name) do
    agent = BaseAgent.init(%{client: %StubClient{}, model: "fast-model"})
    %{agent | name: name}
  end

  defp assert_one_killed(name, model) do
    assert_receive {:run_exception, measurements, metadata, _span_ctx}

    assert %{agent_name: ^name, model: ^model, kind: :exit, reason: :killed, stacktrace: []} =
             metadata

    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert is_integer(measurements.monotonic_time)

    refute_receive {:run_exception, _, _, _}, 50
    {measurements, metadata}
  end

  describe "Reactive" do
    test "race emits one killed exception for the loser it kills", %{name: name} do
      assert {:ok, _} =
               Reactive.race([fast_agent("#{name}-winner"), stuck_agent(name)], "hi")

      assert_one_killed(name, "stuck-model")
    end

    test "race emits nothing for the winner", %{name: name} do
      assert {:ok, _} = Reactive.race([fast_agent(name)], "hi")
      refute_receive {:run_exception, _, _, _}, 50
    end

    test "race emits nothing for an agent process, whose run is not killed", %{name: name} do
      {:ok, pid} = AgentProcess.start_link(agent: stuck_agent(name))
      assert {:ok, _} = Reactive.race([fast_agent("#{name}-winner"), pid], "hi")
      refute_receive {:run_exception, _, _, _}, 50
    end

    test "race attaches the caller's OTel context while emitting", %{name: name} do
      tracer = :opentelemetry.get_application_tracer(__MODULE__)
      caller = :otel_tracer.start_span(:otel_ctx.get_current(), tracer, "caller", %{})
      token = :otel_ctx.attach(:otel_tracer.set_current_span(:otel_ctx.get_current(), caller))

      try do
        assert {:ok, _} =
                 Reactive.race([fast_agent("#{name}-winner"), stuck_agent(name)], "hi")
      after
        :otel_ctx.detach(token)
        :otel_span.end_span(caller)
      end

      assert_receive {:run_exception, _, _, span_ctx}
      assert span_ctx == caller
    end

    test "some emits one killed exception for the agent left running", %{name: name} do
      assert {:ok, _} =
               Reactive.some([fast_agent("#{name}-winner"), stuck_agent(name)], "hi", count: 1)

      assert_one_killed(name, "stuck-model")
    end

    test "all emits one killed exception for an agent past the timeout", %{name: name} do
      assert {:ok, _} = Reactive.all([stuck_agent(name)], "hi", timeout: 100)

      {measurements, _} = assert_one_killed(name, "stuck-model")
      assert measurements.duration >= System.convert_time_unit(100, :millisecond, :native)
    end
  end

  # A run that already stopped must not also get a killed exception when the
  # task is killed later, in a callback that runs after the run.
  describe "a task killed after its run finished" do
    test "race: a loser killed in on_complete emits nothing", %{name: name} do
      gate = :atomics.new(1, [])

      on_complete = fn
        # The winner reports only once the loser's run is over.
        "agent_0", _ ->
          wait_until(fn -> :atomics.get(gate, 1) == 1 end)

        "agent_1", _ ->
          :atomics.put(gate, 1, 1)
          block(nil)
      end

      assert {:ok, _} =
               Reactive.race([fast_agent("#{name}-winner"), fast_agent(name)], "hi",
                 on_complete: on_complete
               )

      refute_receive {:run_exception, _, _, _}, 50
    end

    test "some: an agent killed in on_complete emits nothing", %{name: name} do
      gate = :atomics.new(1, [])

      on_complete = fn
        "agent_0", _ ->
          wait_until(fn -> :atomics.get(gate, 1) == 1 end)

        "agent_1", _ ->
          :atomics.put(gate, 1, 1)
          block(nil)
      end

      assert {:ok, _} =
               Reactive.some([fast_agent("#{name}-winner"), fast_agent(name)], "hi",
                 count: 1,
                 on_complete: on_complete
               )

      refute_receive {:run_exception, _, _, _}, 50
    end

    test "all: a task timed out in on_complete emits nothing", %{name: name} do
      assert {:ok, _} =
               Reactive.all([fast_agent(name)], "hi",
                 timeout: 100,
                 on_complete: fn _, _ -> block(nil) end
               )

      refute_receive {:run_exception, _, _, _}, 50
    end

    test "ParallelOrchestrator.execute: timed out in on_agent_complete emits nothing", %{
      name: name
    } do
      specs = [%{id: "done", agent: fast_agent(name), input: "hi"}]

      assert {:ok, %{errors: %{"done" => {:exit, :timeout}}}} =
               ParallelOrchestrator.execute(specs,
                 timeout: 100,
                 on_agent_complete: fn _, _ -> block(nil) end
               )

      refute_receive {:run_exception, _, _, _}, 50
    end

    test "ParallelOrchestrator.execute_stream: timed out in transform emits nothing", %{
      name: name
    } do
      specs = [%{id: "done", agent: fast_agent(name), input: "hi", transform: &block/1}]

      assert [{:exit, {"done", :timeout}}] =
               specs |> ParallelOrchestrator.execute_stream(timeout: 100) |> Enum.to_list()

      refute_receive {:run_exception, _, _, _}, 50
    end

    test "ParallelOrchestrator.execute_stream reports a kill on every enumeration", %{
      name: name
    } do
      stream =
        ParallelOrchestrator.execute_stream(
          [%{id: "stuck", agent: stuck_agent(name), input: "hi"}],
          timeout: 50
        )

      assert [{:exit, {"stuck", :timeout}}] = Enum.to_list(stream)
      assert [{:exit, {"stuck", :timeout}}] = Enum.to_list(stream)
      assert_receive {:run_exception, _, _, _}
      assert_receive {:run_exception, _, _, _}
    end
  end

  describe "ParallelOrchestrator" do
    test "execute emits one killed exception for an agent past the timeout", %{name: name} do
      specs = [%{id: "stuck", agent: stuck_agent(name), input: "hi"}]

      assert {:ok, %{errors: %{"stuck" => {:exit, :timeout}}}} =
               ParallelOrchestrator.execute(specs, timeout: 100)

      assert_one_killed(name, "stuck-model")
    end

    test "execute_stream emits one killed exception for an agent past the timeout", %{
      name: name
    } do
      specs = [%{id: "stuck", agent: stuck_agent(name), input: "hi"}]

      assert [{:exit, {"stuck", :timeout}}] =
               specs |> ParallelOrchestrator.execute_stream(timeout: 100) |> Enum.to_list()

      assert_one_killed(name, "stuck-model")
    end
  end

  describe "Batch.Processor" do
    test "process_batch emits one killed exception for an item past the timeout", %{
      name: name
    } do
      assert {:ok, [{:error, {:exit, :timeout}}]} =
               Processor.process_batch(stuck_agent(name), [%{chat_message: "hi"}], timeout: 100)

      assert_one_killed(name, "stuck-model")
    end
  end

  describe "KilledRun.emit/3 metadata" do
    test "carries the same run metadata as a live run, plus kind, reason and stacktrace", %{
      name: name
    } do
      agent = %{stuck_agent(name) | session_id: "killed-sess"}

      :ok = Normandy.Telemetry.KilledRun.emit(agent, 5, nil)

      assert_receive {:run_exception, %{duration: 5},
                      %{
                        model: "stuck-model",
                        agent_name: ^name,
                        session_id: "killed-sess",
                        conversation_id: "killed-sess",
                        kind: :exit,
                        reason: :killed,
                        stacktrace: []
                      }, _ctx}
    end
  end
end
