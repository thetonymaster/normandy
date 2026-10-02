defmodule Normandy.Coordination.ParallelOrchestratorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{ParallelOrchestrator, SharedContext}
  alias Normandy.Test.StubClient
  alias Normandy.Test.TaggingClient

  @moduletag :capture_log

  defp agent do
    BaseAgent.init(%{client: %NormandyTest.Support.ModelMockup{}, model: "test-model"})
  end

  defp tagging(name, opts \\ []) do
    BaseAgent.init(%{client: struct(TaggingClient, [name: name] ++ opts), model: "test-model"})
  end

  describe "execute_same_input/3" do
    test "runs agents that have no :transform" do
      agents = [%{id: "a", agent: agent()}, %{id: "b", agent: agent()}]

      assert {:ok, %{success: true, results: results}} =
               ParallelOrchestrator.execute_same_input(agents, "hello")

      assert results |> Map.keys() |> Enum.sort() == ["a", "b"]
    end

    test "applies a :transform when one is given" do
      agents = [%{id: "a", agent: agent(), transform: fn _ -> :transformed end}]

      assert {:ok, %{results: %{"a" => :transformed}}} =
               ParallelOrchestrator.execute_same_input(agents, "hello")
    end
  end

  describe "execute/2 with agent specs" do
    test "each agent runs on its own input; results and context are keyed by id" do
      specs = [
        %{id: "a", agent: tagging("a"), input: "one"},
        %{id: "b", agent: tagging("b"), input: "two"}
      ]

      assert {:ok, %{success: true, results: results, errors: errors, context: ctx}} =
               ParallelOrchestrator.execute(specs, [])

      assert errors == %{}
      assert results["a"].chat_message =~ ~r/^a\(.*one/
      assert results["b"].chat_message =~ ~r/^b\(.*two/
      assert {:ok, %{chat_message: "b(" <> _}} = SharedContext.get(ctx, {"results", "b"})
    end

    test "a failing agent is reported under its id and the others still succeed" do
      specs = [
        %{id: "ok", agent: tagging("ok"), input: "x"},
        %{id: "bad", agent: tagging("bad", fail_on: "x"), input: "x"}
      ]

      assert {:ok, %{success: false, results: results, errors: errors}} =
               ParallelOrchestrator.execute(specs, [])

      assert Map.keys(results) == ["ok"]
      assert %{"bad" => {:exception, %RuntimeError{message: "bad failed"}, _}} = errors
    end

    test ":aggregate receives the successful {id, result} pairs" do
      specs = [
        %{id: "a", agent: tagging("a"), input: "x"},
        %{id: "b", agent: tagging("b"), input: "x"}
      ]

      assert {:ok, %{aggregated: ["a", "b"]}} =
               ParallelOrchestrator.execute(specs,
                 aggregate: fn pairs -> pairs |> Enum.map(&elem(&1, 0)) |> Enum.sort() end
               )
    end

    test ":on_agent_complete is called once per successful agent" do
      parent = self()

      specs = [
        %{id: "a", agent: tagging("a"), input: "x"},
        %{id: "b", agent: tagging("b"), input: "x"}
      ]

      {:ok, _} =
        ParallelOrchestrator.execute(specs,
          on_agent_complete: fn id, _ -> send(parent, {:done, id}) end
        )

      assert_received {:done, "a"}
      assert_received {:done, "b"}
    end

    test "an agent past :timeout fails under its id; the others still finish" do
      specs = [
        %{id: "fast", agent: tagging("fast"), input: "x"},
        %{id: "slow", agent: tagging("slow", sleep_ms: 500), input: "x"}
      ]

      assert {:ok,
              %{success: false, results: %{"fast" => _}, errors: %{"slow" => {:exit, :timeout}}}} =
               ParallelOrchestrator.execute(specs, timeout: 100)
    end

    test "agents run concurrently" do
      specs = for n <- 1..4, do: %{id: "#{n}", agent: tagging("#{n}", sleep_ms: 200), input: "x"}
      start = System.monotonic_time(:millisecond)

      {:ok, %{success: true}} = ParallelOrchestrator.execute(specs, max_concurrency: 4)

      # Four 200 ms agents in sequence would take 800 ms.
      assert System.monotonic_time(:millisecond) - start < 600
    end
  end

  describe "execute/2 with plain agents" do
    test "returns one result per agent, in agent order" do
      assert {:ok, [{:ok, first}, {:ok, second}]} =
               ParallelOrchestrator.execute([tagging("a"), tagging("b")], "go")

      assert first.chat_message =~ "a("
      assert second.chat_message =~ "b("
    end

    test "a failed agent keeps its place as {:error, reason}" do
      assert {:ok, [{:error, {:exception, %RuntimeError{}, _}}, {:ok, _}]} =
               ParallelOrchestrator.execute([tagging("bad", fail_on: "go"), tagging("b")], "go")
    end
  end

  # An agent whose model call exits (as a timed-out GenServer.call does) instead of raising.
  defp exiting_agent,
    do:
      BaseAgent.init(%{client: %StubClient{reply: fn _ -> exit(:boom) end}, model: "test-model"})

  describe "callbacks that raise" do
    test "a raising :transform is the agent's error, not a crash of the caller" do
      specs = [
        %{id: "ok", agent: tagging("ok"), input: "x"},
        %{
          id: "t",
          agent: tagging("t"),
          input: "x",
          transform: fn _ -> raise "transform failed" end
        }
      ]

      assert {:ok, %{results: %{"ok" => _}, errors: %{"t" => {:exception, %RuntimeError{}, _}}}} =
               ParallelOrchestrator.execute(specs)
    end

    test "a raising :on_agent_complete is the agent's error, not a crash of the caller" do
      specs = [%{id: "a", agent: tagging("a"), input: "x"}]

      assert {:ok, %{errors: %{"a" => {:exception, %RuntimeError{}, _}}}} =
               ParallelOrchestrator.execute(specs, on_agent_complete: fn _, _ -> raise "boom" end)
    end

    test "execute_stream/2: a raising :transform is the agent's error" do
      specs = [%{id: "t", agent: tagging("t"), input: "x", transform: fn _ -> raise "no" end}]

      assert [{:ok, {:error, {"t", {:exception, %RuntimeError{}, _}}}}] =
               specs |> ParallelOrchestrator.execute_stream() |> Enum.to_list()
    end
  end

  describe "agents that exit" do
    test "execute/2 reports the exit under the agent's id instead of exiting the caller" do
      specs = [
        %{id: "ok", agent: tagging("ok"), input: "x"},
        %{id: "exits", agent: exiting_agent(), input: "x"}
      ]

      assert {:ok, %{results: %{"ok" => _}, errors: %{"exits" => {:exit, :boom}}}} =
               ParallelOrchestrator.execute(specs)
    end

    test "execute_stream/2 yields the exit as the agent's error" do
      specs = [%{id: "exits", agent: exiting_agent(), input: "x"}]

      assert [{:ok, {:error, {"exits", {:exit, :boom}}}}] =
               specs |> ParallelOrchestrator.execute_stream() |> Enum.to_list()
    end
  end

  describe "execute_stream/2" do
    test "an agent past :timeout is reported by id; the stream goes on" do
      specs = [
        %{id: "fast", agent: tagging("fast"), input: "x"},
        # Killed at the timeout; the margin keeps "fast" in time on a loaded machine.
        %{id: "slow", agent: tagging("slow", sleep_ms: 10_000), input: "x"}
      ]

      outcomes = specs |> ParallelOrchestrator.execute_stream(timeout: 1_000) |> Enum.to_list()

      assert {:exit, {"slow", :timeout}} in outcomes
      assert Enum.any?(outcomes, &match?({:ok, {:ok, {"fast", _}}}, &1))
    end

    test "yields each agent's result or error tagged with its id" do
      specs = [
        %{id: "a", agent: tagging("a"), input: "x"},
        %{id: "bad", agent: tagging("bad", fail_on: "x"), input: "x"}
      ]

      outcomes = specs |> ParallelOrchestrator.execute_stream() |> Enum.map(fn {:ok, r} -> r end)

      assert {:ok, {"a", %{chat_message: "a(" <> _}}} = Enum.find(outcomes, &match?({:ok, _}, &1))

      assert {:error, {"bad", {:exception, %RuntimeError{}, _}}} =
               Enum.find(outcomes, &match?({:error, _}, &1))
    end
  end
end
