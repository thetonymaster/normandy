defmodule Normandy.Telemetry.WorkflowSpan do
  @moduledoc """
  The `[:normandy, :workflow, :run]` span shared by `Normandy.DSL.Workflow` and the
  top-level entry points of the orchestrators in `Normandy.Coordination`.

  Metadata: `:orchestrator` (`:workflow | :sequential | :parallel | :hierarchical`)
  plus whatever identity/size keys the caller passes (`:workflow_name`,
  `:step_count`). The `:stop` adds `:status`: `:error` when `fun` returned
  `{:error, _}`, `:ok` otherwise (every caller returns `{:ok, _} | {:error, _}`).
  It never carries input, output or message content. Agent runs started inside `fun`
  nest under this span (the coordinators propagate the OTel
  context into the tasks they spawn).
  """

  alias Normandy.Telemetry.Span

  @doc """
  Runs `fun` under the span and returns its result.
  """
  @spec span(atom(), map(), (-> result)) :: result when result: var
  def span(orchestrator, metadata, fun) when is_atom(orchestrator) and is_function(fun, 0) do
    metadata = Map.put(metadata, :orchestrator, orchestrator)

    Span.span([:normandy, :workflow, :run], metadata, fn ->
      result = fun.()
      {result, Map.put(metadata, :status, status(result))}
    end)
  end

  defp status({:error, _reason}), do: :error
  defp status(_result), do: :ok
end
