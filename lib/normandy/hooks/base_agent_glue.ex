defmodule Normandy.Hooks.BaseAgentGlue do
  @moduledoc false
  # BaseAgent's hook call sites, so base_agent.ex keeps one-line calls. An agent with no
  # hooks does no hook work: each function checks Runner.hooks?/1 first.

  alias Normandy.Guardrails.ViolationError
  alias Normandy.HookHaltError
  alias Normandy.Hooks.Runner
  alias Normandy.Schema.ValidationError

  @doc "Runs `on_prompt` on the validated input; raises `HookHaltError` on a halt."
  @spec prompt!(map(), term()) :: term()
  def prompt!(config, input) do
    if Runner.hooks?(config), do: run_prompt!(config, input), else: input
  end

  defp run_prompt!(config, input) do
    case Runner.prompt(config, input) do
      {:cont, admitted} ->
        admitted

      {:halt, hook, reason} ->
        raise HookHaltError, event: :on_prompt, hook: hook, reason: reason
    end
  end

  @doc """
  Runs `on_turn_end` for a run that returned. The run's own config carries the memory,
  so the turn's id reaches the hook.
  """
  @spec turn_end_ok(map(), term()) :: :ok
  def turn_end_ok(_config, {%{memory: _} = after_run, response}) do
    if Runner.hooks?(after_run), do: Runner.turn_end(after_run, {:ok, response})
    :ok
  end

  @doc """
  Runs `on_turn_end` for a run that raised, exited or threw. The run's config is lost
  with the exception, so the hook gets `turn_id: nil` rather than the previous turn's.
  The Runner never raises for `on_turn_end`, so the caller re-raises the original.
  """
  @spec turn_end_raised(map(), atom(), term(), Exception.stacktrace()) :: :ok
  def turn_end_raised(config, kind, reason, stacktrace) do
    if Runner.hooks?(config) do
      outcome = raised_outcome(kind, Exception.normalize(kind, reason, stacktrace))
      Runner.turn_end(config, outcome, turn_id: nil)
    end

    :ok
  end

  # Input that never became a turn is :rejected, as Turn.Server reports it; an output
  # guardrail block is a rejection too.
  defp raised_outcome(:error, %HookHaltError{} = e), do: HookHaltError.outcome(e)
  defp raised_outcome(:error, %ValidationError{} = e), do: {:rejected, e}
  defp raised_outcome(:error, %ViolationError{} = e), do: {:rejected, e}
  defp raised_outcome(:error, exception), do: {:error, exception}
  defp raised_outcome(kind, reason), do: {:error, Normandy.TurnError.task_down({kind, reason})}
end
