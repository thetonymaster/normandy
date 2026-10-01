defmodule Normandy.Coordination.HierarchicalCoordinatorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.HierarchicalCoordinator

  # Replies with `reply` merged into the response model and reports each call.
  defmodule CaptureClient do
    @moduledoc false
    use Normandy.Schema

    schema do
      field(:test_pid, :any)
      field(:name, :string)
      field(:reply, :map, default: %{})
      field(:fail, :boolean, default: false)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
        do: response_model

      def converse(client, _model, _temperature, _max_tokens, messages, response_model, _opts) do
        send(client.test_pid, {:llm_call, client.name, messages})
        if client.fail, do: raise("worker down")
        struct(response_model, client.reply)
      end
    end
  end

  defmodule Plan do
    @moduledoc false
    use Normandy.Schema

    io_schema "a manager reply" do
      field(:chat_message, :string, description: "message")
      field(:delegation_plan, {:array, :string}, description: "tasks", default: [])
    end
  end

  defp agent(name, reply, output_schema \\ nil, fail \\ false) do
    config = %{
      client: %CaptureClient{test_pid: self(), name: name, reply: reply, fail: fail},
      model: "test-model"
    }

    config = if output_schema, do: Map.put(config, :output_schema, output_schema), else: config
    BaseAgent.init(config)
  end

  defp coordinator(plan) do
    manager = agent("manager", %{delegation_plan: plan}, %Plan{})

    workers = [
      %{id: "w1", agent: agent("w1", %{chat_message: "r1"})},
      %{id: "w2", agent: agent("w2", %{chat_message: "r2"})}
    ]

    HierarchicalCoordinator.new(
      manager: manager,
      workers: workers,
      delegation_strategy: :round_robin
    )
  end

  # The manager's second call is the aggregation; its last message carries the results.
  defp aggregated_results do
    assert_receive {:llm_call, "manager", _plan_call}
    assert_receive {:llm_call, "manager", messages}
    List.last(messages).content
  end

  test "round-robin keeps every worker result when tasks outnumber workers" do
    tasks = ["t1", "t2", "t3", "t4", "t5"]

    assert {:ok, _} = HierarchicalCoordinator.execute(coordinator(tasks), "go")

    results = aggregated_results()

    for id <- ["w1#1", "w2#1", "w1#2", "w2#2", "w1#3"] do
      assert results =~ id, "aggregation is missing #{id}: #{results}"
    end
  end

  test "a worker with a single task keeps its plain id" do
    assert {:ok, _} = HierarchicalCoordinator.execute(coordinator(["t1", "t2"]), "go")

    results = aggregated_results()
    assert results =~ "## w1\\n"
    refute results =~ "w1#"
  end

  test "the manager prompt reaches the manager" do
    assert {:ok, _} =
             HierarchicalCoordinator.execute(coordinator(["t1"]), "go",
               manager_prompt: "Split it in two"
             )

    assert_receive {:llm_call, "manager", messages}
    assert List.last(messages).content =~ "Split it in two"
  end

  test "failed workers are reported to the manager" do
    manager = agent("manager", %{delegation_plan: ["t1", "t2"]}, %Plan{})

    workers = [
      %{id: "ok", agent: agent("ok", %{chat_message: "fine"})},
      %{id: "bad", agent: agent("bad", %{}, nil, true)}
    ]

    coordinator = HierarchicalCoordinator.new(manager: manager, workers: workers)
    assert {:ok, _} = HierarchicalCoordinator.execute(coordinator, "go")

    results = aggregated_results()
    assert results =~ "bad"
    assert results =~ "worker down"
  end

  describe "execute_with_tasks/3" do
    test "two tasks for one worker both reach the manager" do
      tasks = [%{worker_id: "w1", task: "a"}, %{worker_id: "w1", task: "b"}]

      assert {:ok, _} = HierarchicalCoordinator.execute_with_tasks(coordinator([]), tasks)

      assert_receive {:llm_call, "manager", messages}
      results = List.last(messages).content
      assert results =~ "w1#1"
      assert results =~ "w1#2"
    end

    test "an unknown worker id raises a clear error" do
      assert_raise ArgumentError, ~r/no worker "nope"/, fn ->
        HierarchicalCoordinator.execute_with_tasks(coordinator([]), [
          %{worker_id: "nope", task: "a"}
        ])
      end
    end
  end
end
