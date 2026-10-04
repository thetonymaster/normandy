defmodule Normandy.Hooks.ServerGlue do
  @moduledoc false
  # Turn.Server's hook logic, so server.ex keeps one-line call sites. Every call the
  # server makes into hook code goes through its call_handler/3, so no hook outcome
  # terminates the server.

  alias Normandy.Hooks.Runner

  @doc "The `on_turn_end` outcome of a failed turn: an output-guardrail block stays a rejection."
  @spec fail_outcome(term()) :: Normandy.Behaviours.Hooks.outcome()
  def fail_outcome({:rejected, exception}), do: {:rejected, exception}
  def fail_outcome(reason), do: {:error, reason}

  @doc """
  Whether a loaded session is new (its store held no entries and no turn state) and has
  `on_session_start` hooks.
  """
  @spec session_start?(map() | nil, term()) :: boolean()
  def session_start?(nil, _turn_state), do: false

  def session_start?(config, turn_state) do
    turn_state == nil and config.memory.head == nil and
      Runner.handles?(config, :on_session_start)
  end

  @doc """
  Runs `on_session_start`. Returns the texts of all entries joined by a blank line, so
  they are stored as one entry (all or none), or `nil` when nothing was injected.
  """
  @spec session_start(map()) :: String.t() | nil
  def session_start(config) do
    case Runner.session_start(config) do
      [] -> nil
      texts -> Enum.join(texts, "\n\n")
    end
  end
end
