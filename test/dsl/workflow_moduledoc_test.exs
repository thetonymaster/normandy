defmodule Normandy.DSL.WorkflowModuledocTest do
  @moduledoc """
  Task 7.0c (row 6): the first example in `Normandy.DSL.Workflow`'s moduledoc compiles,
  with no warning, and runs: every step's agent gets text it accepts, including the step
  after the parallel one, whose input is the map of the parallel agents' results.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema}
  alias Normandy.Test.StubClient

  # The example's workflow module, from `defmodule` up to the `execute` call below it.
  defp example_source do
    {:docs_v1, _, :elixir, _, %{"en" => doc}, _, _} = Code.fetch_docs(Normandy.DSL.Workflow)
    [_, example] = Regex.run(~r/## Examples\n\n(.*?)\n\n +# Execute the workflow/s, doc)

    example
    |> String.split("\n")
    |> Enum.map_join("\n", &String.replace_prefix(&1, "    ", ""))
  end

  defp agent(name) do
    reply = fn _response_model -> %BaseAgentOutputSchema{chat_message: "#{name} answered"} end
    BaseAgent.init(%{client: %StubClient{reply: reply}, model: "m"})
  end

  test "the moduledoc's workflow example runs with agents that answer text" do
    # No compiler warning either: its when_result clauses never return {:error, _} or
    # {:ok, _}, which a workflow must be free to do.
    # Diagnostics are collected per process, so another async test's compile warning on
    # the global stderr cannot reach this assertion.
    {[{module, _bytecode}], diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(example_source()) end)

    # A repeated run (--repeat-until-failure) must not see its own earlier definition.
    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    assert diagnostics == []

    agents =
      Map.new(
        [:ResearchAgent, :AnalysisAgent, :FactCheckAgent, :QualityAgent, :ReviewAgent],
        &{Module.concat([&1]), agent(&1)}
      )

    assert {:ok, results} = module.execute(agents: agents, initial_input: "quantum computing")
    assert results.final_review == :needs_revision

    assert %{fact_check: {:ok, %BaseAgentOutputSchema{}}, quality_check: {:ok, _}} =
             results.validate
  end
end
