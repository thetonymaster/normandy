defmodule Normandy.OrchestrationError do
  @moduledoc """
  One or more agents of a `Normandy.Coordination.SequentialOrchestrator.execute/3` or
  `Normandy.Coordination.ParallelOrchestrator.execute/3` call failed.

    * `:results` - `%{agent_id => output}` for the agents that succeeded.
    * `:errors` - `%{agent_id => exception}` for the agents that failed: Normandy's own
      exception (`Normandy.LLMError`, `Normandy.Schema.ValidationError`, ...), the
      exception a bug raised (logged with its stacktrace where it was raised; the
      stacktrace is not kept here), or a `:task_down` `Normandy.TurnError` for an agent
      that exited (`reason` the exit reason) or ran past `:timeout` (`reason: :timeout`).

  An agent in neither map did not run (`SequentialOrchestrator` with `on_error: :stop`).
  The message names the failed agents and their exception modules, never values from
  them.
  """
  defexception results: %{}, errors: %{}

  @type t :: %__MODULE__{
          results: %{String.t() => term()},
          errors: %{String.t() => Exception.t()}
        }

  @impl true
  def message(%__MODULE__{errors: errors}) do
    failed =
      errors
      |> Enum.sort_by(fn {id, _exception} -> id end)
      |> Enum.map_join(", ", fn {id, %module{}} -> "#{inspect(id)} (#{inspect(module)})" end)

    "#{map_size(errors)} agent(s) failed: #{failed}"
  end
end
