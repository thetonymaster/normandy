defmodule Normandy.DSL.WorkflowTest do
  use ExUnit.Case, async: true

  # Define simple agents for testing
  defmodule SimpleAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      system_prompt("You are a simple agent.")
    end
  end

  defmodule ProcessAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      system_prompt("You process data.")
    end
  end

  defmodule ValidateAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      system_prompt("You validate data.")
    end
  end

  # Define a test workflow with sequential steps
  defmodule SequentialWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      step :first do
        agent(SimpleAgent)
        input("initial input")
      end

      step :second do
        agent(ProcessAgent)
        input(from: :first)
      end
    end
  end

  # Define a workflow with parallel execution
  defmodule ParallelWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      step :gather do
        agent(SimpleAgent)
        input("gather data")
      end

      parallel :process do
        agent(ProcessAgent, name: :processor)
        agent(ValidateAgent, name: :validator)
        input(from: :gather)
      end
    end
  end

  # Define a workflow with race execution
  defmodule RaceWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      race :fastest do
        agent(SimpleAgent, name: :fast1)
        agent(ProcessAgent, name: :fast2)
        input("race input")
      end
    end
  end

  describe "workflow definition" do
    test "steps/0 returns workflow steps" do
      steps = SequentialWorkflow.steps()

      assert length(steps) == 2
      assert Enum.at(steps, 0).name == :first
      assert Enum.at(steps, 0).type == :sequential
      assert Enum.at(steps, 1).name == :second
      assert Enum.at(steps, 1).type == :sequential
    end

    test "steps/0 for parallel workflow" do
      steps = ParallelWorkflow.steps()

      assert length(steps) == 2
      assert Enum.at(steps, 1).name == :process
      assert Enum.at(steps, 1).type == :parallel
      assert length(Enum.at(steps, 1).agents) == 2
    end

    test "steps/0 for race workflow" do
      steps = RaceWorkflow.steps()

      assert length(steps) == 1
      assert Enum.at(steps, 0).name == :fastest
      assert Enum.at(steps, 0).type == :race
    end
  end

  # A client whose reply carries text: a chained step feeds the previous reply to
  # the next agent, and the default input schema rejects a nil chat_message.
  defp text_client do
    %Normandy.Test.StubClient{reply: fn model -> Map.put(model, :chat_message, "ok") end}
  end

  describe "execute/1" do
    setup do
      client = text_client()

      simple_agent = SimpleAgent.new(client: client)
      process_agent = ProcessAgent.new(client: client)
      validate_agent = ValidateAgent.new(client: client)

      agents_map = %{
        SimpleAgent => simple_agent,
        ProcessAgent => process_agent,
        ValidateAgent => validate_agent
      }

      {:ok, agents: agents_map}
    end

    test "executes sequential workflow", %{agents: agents_map} do
      result = SequentialWorkflow.execute(agents: agents_map, initial_input: "test")

      assert {:ok, results} = result
      assert Map.has_key?(results, :first)
      assert Map.has_key?(results, :second)
    end

    test "executes parallel workflow", %{agents: agents_map} do
      result = ParallelWorkflow.execute(agents: agents_map, initial_input: "test")

      assert {:ok, results} = result
      assert Map.has_key?(results, :gather)
      assert Map.has_key?(results, :process)

      # Parallel results should have named agents
      process_results = results.process
      assert Map.has_key?(process_results, :processor)
      assert Map.has_key?(process_results, :validator)
    end

    test "executes race workflow", %{agents: agents_map} do
      result = RaceWorkflow.execute(agents: agents_map, initial_input: "test")

      assert {:ok, results} = result
      assert Map.has_key?(results, :fastest)
      # Race should return single result (first to complete)
      assert is_map(results.fastest)
    end

    test "returns error for missing agent", %{agents: agents_map} do
      # Remove an agent from the map
      incomplete_map = Map.delete(agents_map, ProcessAgent)

      result = SequentialWorkflow.execute(agents: incomplete_map, initial_input: "test")

      assert {:error, {:second, {:missing_agent, ProcessAgent}}} = result
    end

    test ":context is no longer an option (DX-24)", %{agents: agents_map} do
      assert_raise ArgumentError,
                   "Normandy.DSL.WorkflowTest.SequentialWorkflow.execute/1: unknown option " <>
                     ":context; supported: :agents, :initial_input",
                   fn ->
                     SequentialWorkflow.execute(
                       agents: agents_map,
                       initial_input: "test",
                       context: %{user_id: 123}
                     )
                   end
    end
  end

  describe "data flow" do
    test "input from previous step", %{} do
      steps = SequentialWorkflow.steps()
      second_step = Enum.at(steps, 1)

      assert second_step.input == [from: :first]
    end

    test "static input", %{} do
      steps = SequentialWorkflow.steps()
      first_step = Enum.at(steps, 0)

      assert first_step.input == "initial input"
    end
  end

  describe "agent configuration" do
    test "sequential step has single agent", %{} do
      steps = SequentialWorkflow.steps()
      first_step = Enum.at(steps, 0)

      assert length(first_step.agents) == 1
      assert hd(first_step.agents).module == SimpleAgent
    end

    test "parallel step has multiple agents with names", %{} do
      steps = ParallelWorkflow.steps()
      parallel_step = Enum.at(steps, 1)

      assert length(parallel_step.agents) == 2

      agent_names = Enum.map(parallel_step.agents, & &1.name)
      assert :processor in agent_names
      assert :validator in agent_names
    end

    test "race step has multiple agents", %{} do
      steps = RaceWorkflow.steps()
      race_step = Enum.at(steps, 0)

      assert length(race_step.agents) == 2
    end
  end

  # Orchestrator spans from concurrent async tests carry no :workflow_name.
  def handle_workflow_span(event, _m, metadata, parent) do
    if Map.get(metadata, :workflow_name) == SequentialWorkflow,
      do: send(parent, {event, metadata})
  end

  describe "telemetry" do
    test "execute/1 emits one [:normandy, :workflow, :run] span with identity and size only" do
      client = text_client()
      simple_agent = SimpleAgent.new(client: client)
      process_agent = ProcessAgent.new(client: client)

      handler_id = "workflow-span-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach_many(
        handler_id,
        [[:normandy, :workflow, :run, :start], [:normandy, :workflow, :run, :stop]],
        &__MODULE__.handle_workflow_span/4,
        parent
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _} =
               SequentialWorkflow.execute(
                 agents: %{SimpleAgent => simple_agent, ProcessAgent => process_agent},
                 initial_input: "secret prompt"
               )

      assert_receive {[:normandy, :workflow, :run, :start], start_meta}
      assert_receive {[:normandy, :workflow, :run, :stop], _}
      refute_receive {[:normandy, :workflow, :run, :start], _}

      assert Map.delete(start_meta, :telemetry_span_context) == %{
               workflow_name: SequentialWorkflow,
               orchestrator: :workflow,
               step_count: 2
             }
    end
  end
end
