defmodule Normandy.Coordination.HierarchicalCoordinatorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.HierarchicalCoordinator
  alias Normandy.TurnError

  import ExUnit.CaptureLog

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
      def converse(client, request, _opts) do
        send(client.test_pid, {:llm_call, client.name, request.messages})
        if client.fail, do: raise("worker down")
        {:ok, %Normandy.LLM.Response{content: struct(request.response_model, client.reply)}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
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

  defmodule AssignmentPlan do
    @moduledoc false
    use Normandy.Schema

    io_schema "a manager reply that assigns tasks by worker id" do
      field(:chat_message, :string, description: "message")
      field(:delegation_plan, :map, description: "worker id => task", default: %{})
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
    assert results =~ "## w1\n"
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

    test "a numbered id never takes another worker's id" do
      coordinator =
        HierarchicalCoordinator.new(
          manager: agent("manager", %{delegation_plan: []}, %Plan{}),
          workers: [
            %{id: "w1", agent: agent("w1", %{chat_message: "r1"})},
            %{id: "w1#1", agent: agent("w1#1", %{chat_message: "other"})}
          ]
        )

      tasks = [
        %{worker_id: "w1", task: "a"},
        %{worker_id: "w1", task: "b"},
        %{worker_id: "w1#1", task: "c"}
      ]

      assert {:ok, _} = HierarchicalCoordinator.execute_with_tasks(coordinator, tasks)
      assert_receive {:llm_call, "manager", messages}
      results = List.last(messages).content

      # The content is JSON-encoded: each section starts "## <id>" and ends in "\\n".
      ids = Regex.scan(~r/## ([^\s\\]+)/, results, capture: :all_but_first) |> List.flatten()
      assert length(ids) == 3
      assert ids == Enum.uniq(ids)
      assert results =~ "other"
    end

    test "a worker that is not an agent config is reported by the public function" do
      coordinator = HierarchicalCoordinator.add_worker(coordinator([]), "w", :not_an_agent)

      error =
        assert_raise ArgumentError, fn ->
          HierarchicalCoordinator.execute_with_tasks(coordinator, [%{worker_id: "w", task: "a"}])
        end

      assert error.message =~
               ~r/^Normandy\.Coordination\.HierarchicalCoordinator\.execute_with_tasks\/3: /
    end

    test "an unknown worker id raises a clear error" do
      assert_raise ArgumentError, ~r/no worker "nope"/, fn ->
        HierarchicalCoordinator.execute_with_tasks(coordinator([]), [
          %{worker_id: "nope", task: "a"}
        ])
      end
    end
  end

  describe "delegation strategies" do
    defp workers do
      [
        %{id: "w1", agent: agent("w1", %{chat_message: "r1"})},
        %{id: "w2", agent: agent("w2", %{chat_message: "r2"})}
      ]
    end

    defp worker_input(name) do
      assert_receive {:llm_call, ^name, messages}
      List.last(messages).content
    end

    test ":broadcast sends the original input to every worker" do
      coordinator =
        HierarchicalCoordinator.new(
          manager: agent("manager", %{delegation_plan: ["ignored"]}, %Plan{}),
          workers: workers(),
          delegation_strategy: :broadcast
        )

      assert {:ok, _} = HierarchicalCoordinator.execute(coordinator, "the original")

      assert worker_input("w1") =~ "the original"
      assert worker_input("w2") =~ "the original"
    end

    test ":conditional sends each worker the task the manager assigned to its id" do
      coordinator =
        HierarchicalCoordinator.new(
          manager:
            agent("manager", %{delegation_plan: %{"w2" => "only for w2"}}, %AssignmentPlan{}),
          workers: workers(),
          delegation_strategy: :conditional
        )

      assert {:ok, _} = HierarchicalCoordinator.execute(coordinator, "x")

      assert worker_input("w2") =~ "only for w2"
      refute_received {:llm_call, "w1", _}
    end

    test ":conditional reads a task under the worker id as an atom key" do
      coordinator =
        HierarchicalCoordinator.new(
          manager:
            agent("manager", %{delegation_plan: %{w2: "atom key for w2"}}, %AssignmentPlan{}),
          workers: workers(),
          delegation_strategy: :conditional
        )

      assert {:ok, _} = HierarchicalCoordinator.execute(coordinator, "x")

      assert worker_input("w2") =~ "atom key for w2"
      refute_received {:llm_call, "w1", _}
    end

    test ":conditional creates no atom from a worker id" do
      # A fresh id: no atom of that name exists, and looking it up must not create one.
      id = "w-#{System.unique_integer([:positive])}-not-an-atom"

      coordinator =
        HierarchicalCoordinator.new(
          manager: agent("manager", %{delegation_plan: %{"w1" => "t"}}, %AssignmentPlan{}),
          workers: [%{id: id, agent: agent("w1", %{chat_message: "r1"})}],
          delegation_strategy: :conditional
        )

      assert {:ok, _} = HierarchicalCoordinator.execute(coordinator, "x")
      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end
    end
  end

  describe "workers and failures" do
    test "add_worker/3 and remove_worker/2 change who gets tasks" do
      coordinator =
        ["a", "b"]
        |> coordinator()
        |> HierarchicalCoordinator.remove_worker("w1")
        |> HierarchicalCoordinator.add_worker("w3", agent("w3", %{chat_message: "r3"}))

      assert Enum.map(coordinator.workers, & &1.id) == ["w2", "w3"]
      assert {:ok, _} = HierarchicalCoordinator.execute(coordinator, "x")

      assert_receive {:llm_call, "w2", _}
      assert_receive {:llm_call, "w3", _}
      refute_received {:llm_call, "w1", _}
    end

    test "a manager whose model call exits returns a :task_down TurnError" do
      exiting =
        BaseAgent.init(%{
          client: %Normandy.Test.StubClient{reply: fn _ -> exit(:boom) end},
          model: "test-model"
        })

      coordinator =
        HierarchicalCoordinator.new(
          manager: exiting,
          workers: [%{id: "w1", agent: agent("w1", %{chat_message: "r1"})}]
        )

      assert {:error, {:manager_failed, %TurnError{type: :task_down, reason: :boom}}} =
               HierarchicalCoordinator.execute(coordinator, "x")
    end

    test "a manager whose aggregation call exits returns a :task_down TurnError" do
      calls = :counters.new(1, [])

      # Plans on the first call, exits on the second (the aggregation).
      reply = fn response_model ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1,
          do: %{response_model | delegation_plan: ["t1"]},
          else: exit(:boom)
      end

      manager =
        BaseAgent.init(%{
          client: %Normandy.Test.StubClient{reply: reply},
          model: "test-model",
          output_schema: %Plan{}
        })

      coordinator =
        HierarchicalCoordinator.new(
          manager: manager,
          workers: [%{id: "w1", agent: agent("w1", %{chat_message: "r1"})}]
        )

      assert {:error, {:aggregation_failed, %TurnError{type: :task_down, reason: :boom}}} =
               HierarchicalCoordinator.execute(coordinator, "x")
    end

    test "a manager that raises returns the bare exception and logs arities only" do
      coordinator =
        HierarchicalCoordinator.new(
          manager: agent("manager", %{}, %Plan{}, true),
          workers: [%{id: "w1", agent: agent("w1", %{chat_message: "r1"})}]
        )

      log =
        capture_log(fn ->
          assert {:error, {:manager_failed, %RuntimeError{message: "worker down"}}} =
                   HierarchicalCoordinator.execute(coordinator, "x")
        end)

      assert log =~ "HierarchicalCoordinator manager (planning) raised RuntimeError"
      assert log =~ ~r/Normandy\.Agents\.BaseAgent\.\S+\/\d+/
    end

    test "a manager whose model call throws returns a :task_down TurnError" do
      throwing =
        BaseAgent.init(%{
          client: %Normandy.Test.StubClient{reply: fn _ -> throw(:boom) end},
          model: "test-model"
        })

      coordinator =
        HierarchicalCoordinator.new(
          manager: throwing,
          workers: [%{id: "w1", agent: agent("w1", %{chat_message: "r1"})}]
        )

      assert {:error, {:manager_failed, %TurnError{type: :task_down, reason: {:nocatch, :boom}}}} =
               HierarchicalCoordinator.execute(coordinator, "x")
    end

    test "a manager whose model call returns a Normandy error returns it bare" do
      failing =
        BaseAgent.init(%{
          client: %Normandy.Test.StubClient{
            reply: fn _ ->
              {:error, Normandy.LLMError.new(type: :overloaded, retryable?: false)}
            end
          },
          model: "test-model"
        })

      coordinator =
        HierarchicalCoordinator.new(
          manager: failing,
          workers: [%{id: "w1", agent: agent("w1", %{chat_message: "r1"})}]
        )

      assert {:error, {:manager_failed, %Normandy.LLMError{type: :overloaded}}} =
               HierarchicalCoordinator.execute(coordinator, "x")
    end
  end
end
