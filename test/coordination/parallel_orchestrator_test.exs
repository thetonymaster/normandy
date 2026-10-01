defmodule Normandy.Coordination.ParallelOrchestratorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{ParallelOrchestrator, SharedContext}
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
      assert {:ok, [first, second]} =
               ParallelOrchestrator.execute([tagging("a"), tagging("b")], "go")

      assert first.chat_message =~ "a("
      assert second.chat_message =~ "b("
    end
  end

  describe "execute_stream/2" do
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
