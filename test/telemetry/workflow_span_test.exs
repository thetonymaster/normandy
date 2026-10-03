defmodule NormandyTest.Telemetry.WorkflowSpanTest do
  @moduledoc """
  Each public orchestrator entry point emits exactly one
  `[:normandy, :workflow, :run]` span, carrying `:orchestrator` and `:step_count`.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent

  alias Normandy.Coordination.{
    AgentMessage,
    HierarchicalCoordinator,
    ParallelOrchestrator,
    SequentialOrchestrator
  }

  alias Normandy.Test.TaggingClient

  defp agent(name),
    do: BaseAgent.init(%{client: %TaggingClient{name: name}, model: "test-model"})

  defp specs, do: [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b")}]

  # Runs `fun` and returns every workflow span event seen. Telemetry handlers are
  # global, so the module is not async.
  defp workflow_spans(fun) do
    handler_id = "workflow-span-#{System.unique_integer([:positive])}"
    parent = self()
    ref = make_ref()

    :telemetry.attach_many(
      handler_id,
      [[:normandy, :workflow, :run, :start], [:normandy, :workflow, :run, :stop]],
      fn event, _m, metadata, _ ->
        send(parent, {ref, event, metadata})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    receive_spans(ref, [])
  end

  defp receive_spans(ref, acc) do
    receive do
      {^ref, event, metadata} -> receive_spans(ref, [{event, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp assert_one_span(spans, orchestrator, step_count) do
    mine = Enum.filter(spans, fn {_e, m} -> m.orchestrator == orchestrator end)
    assert [{[_, _, _, :start], start}, {[_, _, _, :stop], _}] = mine
    assert start.step_count == step_count
    refute Map.has_key?(start, :workflow_name)
  end

  test "SequentialOrchestrator.execute/3" do
    spans = workflow_spans(fn -> {:ok, _} = SequentialOrchestrator.execute(specs(), "x", []) end)
    assert_one_span(spans, :sequential, 2)
  end

  test "SequentialOrchestrator.execute/3 simple API" do
    spans = workflow_spans(fn -> {:ok, _} = SequentialOrchestrator.execute([agent("a")], "x") end)
    assert_one_span(spans, :sequential, 1)
  end

  test "SequentialOrchestrator.execute_with_messages/3" do
    msg = AgentMessage.new(from: "user", to: "a", type: "request", payload: %{chat_message: "hi"})

    spans =
      workflow_spans(fn ->
        {:ok, _} = SequentialOrchestrator.execute_with_messages(specs(), msg)
      end)

    assert_one_span(spans, :sequential, 2)
  end

  test "ParallelOrchestrator.execute/2" do
    input = %{chat_message: "x"}
    ps = Enum.map(specs(), &Map.put(&1, :input, input))
    spans = workflow_spans(fn -> {:ok, _} = ParallelOrchestrator.execute(ps, []) end)
    assert_one_span(spans, :parallel, 2)
  end

  test "ParallelOrchestrator.execute/2 simple API" do
    spans = workflow_spans(fn -> {:ok, _} = ParallelOrchestrator.execute([agent("a")], "x") end)
    assert_one_span(spans, :parallel, 1)
  end

  test "ParallelOrchestrator.execute_same_input/3" do
    spans =
      workflow_spans(fn -> {:ok, _} = ParallelOrchestrator.execute_same_input(specs(), "x") end)

    assert_one_span(spans, :parallel, 2)
  end

  describe "HierarchicalCoordinator" do
    defp coordinator do
      HierarchicalCoordinator.new(
        manager: agent("manager"),
        workers: [%{id: "w1", agent: agent("w1")}, %{id: "w2", agent: agent("w2")}],
        delegation_strategy: :broadcast
      )
    end

    test "execute/3 emits one hierarchical span and no nested parallel span" do
      spans =
        workflow_spans(fn -> {:ok, _} = HierarchicalCoordinator.execute(coordinator(), "x") end)

      assert_one_span(spans, :hierarchical, 2)
      refute Enum.any?(spans, fn {_e, m} -> m.orchestrator == :parallel end)
    end

    test "execute_with_tasks/3 emits one hierarchical span and no nested parallel span" do
      tasks = [%{worker_id: "w1", task: "a"}]

      spans =
        workflow_spans(fn ->
          {:ok, _} = HierarchicalCoordinator.execute_with_tasks(coordinator(), tasks)
        end)

      assert_one_span(spans, :hierarchical, 1)
      refute Enum.any?(spans, fn {_e, m} -> m.orchestrator == :parallel end)
    end
  end
end
