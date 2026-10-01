defmodule Normandy.Coordination.ParallelOrchestratorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.ParallelOrchestrator

  defp agent do
    BaseAgent.init(%{client: %NormandyTest.Support.ModelMockup{}, model: "test-model"})
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
end
