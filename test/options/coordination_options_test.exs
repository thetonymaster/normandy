defmodule Normandy.Options.CoordinationOptionsTest do
  use ExUnit.Case, async: true

  import Normandy.Test.OptionsAssertions

  alias Normandy.Agents.BaseAgent
  alias Normandy.Batch.Processor

  alias Normandy.Coordination.{
    AgentPool,
    AgentProcess,
    AgentSupervisor,
    HierarchicalCoordinator,
    ParallelOrchestrator,
    Reactive
  }

  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Test.StubClient

  defmodule OneStepWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      step :only do
        agent(OptionsProbeAgent)
        input("go")
      end
    end
  end

  # {misspelled key, {module, function, args}}; each call raises before it touches its
  # other arguments, so they are placeholders.
  @cases [
    {:agnt, {AgentProcess, :start_link, [[agnt: :x]]}},
    {:timout, {AgentProcess, :run, [:no_server, "hi", [timout: 1]]}},
    {:replyto, {AgentProcess, :cast, [:no_server, "hi", [replyto: :x]]}},
    {:max_restart, {AgentSupervisor, :start_link, [[max_restart: 1]]}},
    {:restrat, {AgentSupervisor, :start_agent, [:no_sup, [restrat: :temporary]]}},
    {:sise, {AgentPool, :start_link, [[sise: 3]]}},
    {:timout, {AgentPool, :transaction, [:no_pool, [timout: 1], &Function.identity/1]}},
    {:blok, {AgentPool, :checkout, [:no_pool, [blok: false]]}},
    {:max_concurency, {ParallelOrchestrator, :execute_stream, [[], [max_concurency: 2]]}},
    {:workrs, {HierarchicalCoordinator, :new, [[workrs: []]]}},
    {:max_concurency,
     {HierarchicalCoordinator, :execute, [%HierarchicalCoordinator{}, "go", [max_concurency: 2]]}},
    {:max_concurency,
     {HierarchicalCoordinator, :execute_with_tasks,
      [%HierarchicalCoordinator{}, [], [max_concurency: 2]]}},
    {:timout, {Reactive, :race, [[], "go", [timout: 1]]}},
    {:fail_fats, {Reactive, :all, [[], "go", [fail_fats: true]]}},
    {:cuont, {Reactive, :some, [[], "go", [cuont: 1]]}},
    {:max_concurency, {Processor, :process_batch, [:agent, [], [max_concurency: 2]]}},
    {:ordered, {Processor, :process_batch_with_stats, [:agent, [], [ordered: true]]}},
    {:chunk_sise, {Processor, :process_batch_chunked, [:agent, [], [chunk_sise: 2]]}},
    {:max_concurency, {BaseAgent, :process_batch, [:agent, [], [max_concurency: 2]]}},
    {:ordered, {BaseAgent, :process_batch_with_stats, [:agent, [], [ordered: true]]}},
    {:initial_imput, {OneStepWorkflow, :execute, [[initial_imput: "go"]]}},
    {:failure_treshold, {CircuitBreaker, :start_link, [[failure_treshold: 3]]}}
  ]

  for {key, {mod, fun, args}} <- @cases do
    test "#{inspect(mod)}.#{fun}/#{length(args)} rejects #{inspect(key)}" do
      assert_rejects(unquote(key), unquote(mod), unquote(fun), unquote(Macro.escape(args)))
    end
  end

  # OneStepWorkflow is compiled from this .exs file and has no docs chunk (its execute/1 doc
  # is the DSL's @execute_doc).
  test "every entry point documents its options" do
    for {_key, {mod, fun, args}} <- @cases, mod != OneStepWorkflow do
      assert_documents_options(mod, fun, length(args))
    end
  end

  defp agent, do: BaseAgent.init(%{client: %StubClient{}, model: "m"})

  describe "behaviour the schemas must keep" do
    test "AgentSupervisor.start_agent/2 accepts :restart" do
      sup = start_supervised!(AgentSupervisor)
      assert {:ok, pid} = AgentSupervisor.start_agent(sup, agent: agent(), restart: :temporary)
      assert is_pid(pid)
    end

    test "an unknown :turn_engine raises in the caller instead of crashing init/1" do
      error =
        assert_raise ArgumentError, fn ->
          AgentProcess.start_link(agent: agent(), turn_engine: :async)
        end

      assert error.message =~
               "invalid value for :turn_engine option: expected one of [:inline, :server], got: :async"
    end

    test "a misspelled circuit_breaker option raises when the agent is built" do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.init(
            model: "m",
            client: %StubClient{},
            circuit_breaker: [failure_treshold: 3]
          )
        end

      assert error.message =~ ":failure_treshold"
    end

    test "a server-mode option Turn.Session.new/1 would reject raises in the caller" do
      for {key, value} <- [handlers: %{}, store: {nil, :h}, supervisor: "sup"] do
        error =
          assert_raise ArgumentError, fn ->
            AgentProcess.start_link([agent: agent(), turn_engine: :server] ++ [{key, value}])
          end

        assert error.message =~ "Normandy.Coordination.AgentProcess.start_link/1: "
        assert error.message =~ inspect(key)
      end
    end

    # The model mockup answers, so each run succeeds; :infinity used to raise ArithmeticError.
    test "Reactive.race/3 and some/3 take timeout: :infinity" do
      answering = BaseAgent.init(%{client: %NormandyTest.Support.ModelMockup{}, model: "m"})

      assert {:ok, _} = Reactive.race([answering], "go", timeout: :infinity)
      assert {:ok, results} = Reactive.some([answering], "go", count: 1, timeout: :infinity)
      assert map_size(results) == 1
    end

    test "a :workers value that is not a list is rejected without echoing it" do
      worker = %{id: "w", agent: %{client: %{api_key: "sk-secret"}}}

      error =
        assert_raise ArgumentError, fn ->
          HierarchicalCoordinator.new(manager: agent(), workers: worker)
        end

      assert error.message =~ ":workers"
      refute error.message =~ "sk-secret"
    end

    test "a bad :agent value is rejected without echoing it" do
      error =
        assert_raise ArgumentError, fn ->
          AgentProcess.start_link(agent: %{client: %{api_key: "sk-secret"}})
        end

      assert error.message =~ "Normandy.Coordination.AgentProcess.start_link/1: "
      assert error.message =~ ":agent"
      refute error.message =~ "sk-secret"
    end

    test "a misspelled key inside :agent_config raises in the caller" do
      error =
        assert_raise ArgumentError, fn ->
          AgentPool.start_link(agent_config: %{model: "m", client: %StubClient{}, modle: 1})
        end

      assert error.message =~
               ~r/^Normandy\.Coordination\.AgentPool\.start_link\/1: invalid :agent_config: Normandy\.Agents\.BaseAgent\.init\/1: unknown option :modle/
    end

    test "a struct where AgentPool expects an agent config map is an ArgumentError" do
      error = assert_raise ArgumentError, fn -> AgentPool.start_link(agent_config: %URI{}) end
      assert error.message =~ "Normandy.Coordination.AgentPool.start_link/1: "
      assert error.message =~ ":agent_config"
    end
  end
end
