defmodule Normandy.Hooks.ServerGlue do
  @moduledoc false
  # Turn.Server's hook logic, so server.ex keeps one-line call sites. Every call the
  # server makes into hook code goes through its call_handler/3, so no hook outcome
  # terminates the server.

  @doc "The `on_turn_end` outcome of a failed turn: an output-guardrail block stays a rejection."
  @spec fail_outcome(term()) :: Normandy.Behaviours.Hooks.outcome()
  def fail_outcome({:rejected, exception}), do: {:rejected, exception}
  def fail_outcome(reason), do: {:error, reason}
end
