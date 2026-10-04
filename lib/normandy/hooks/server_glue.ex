defmodule Normandy.Hooks.ServerGlue do
  @moduledoc false
  # Turn.Server's hook logic, so server.ex keeps one-line call sites. Every call the
  # server makes into hook code goes through its call_handler/3, so no hook outcome
  # terminates the server.

  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Turn
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
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

  @doc """
  Runs `after_tool` on a result the server built (an interrupted result). `call` may be a
  raw tool-call map; the result answers its id.
  """
  @spec after_tool(map(), ToolCall.t() | map(), ToolResult.t()) :: ToolResult.t()
  def after_tool(config, call, %ToolResult{} = result) do
    if Runner.hooks?(config) do
      call = Dispatch.to_tool_call(call)
      %{Runner.after_tool(config, call, result) | tool_call_id: call.id}
    else
      result
    end
  end

  @doc """
  Runs `after_tool` on the results the core built for `calls` (approval rejected or
  expired) in one `Turn.step/2` result: in its append effects and in the state's held
  results (kept while approved calls run). Other results are left alone: they passed
  `after_tool` in `Dispatch`.
  """
  @spec after_tool_built(map(), [ToolCall.t()], {Turn.State.t(), list()}) ::
          {Turn.State.t(), list()}
  def after_tool_built(config, calls, {state, effects} = step) do
    if calls != [] and Runner.handles?(config, :after_tool) do
      by_id = Map.new(calls, &{&1.id, &1})
      answer = &answer_built(config, by_id, &1)

      {%{state | held_results: Enum.map(state.held_results, answer)},
       Enum.map(effects, fn
         {:append_message, "tool", result} -> {:append_message, "tool", answer.(result)}
         effect -> effect
       end)}
    else
      step
    end
  end

  defp answer_built(config, by_id, %ToolResult{tool_call_id: id} = result)
       when is_map_key(by_id, id),
       do: %{Runner.after_tool(config, Map.fetch!(by_id, id), result) | tool_call_id: id}

  defp answer_built(_config, _by_id, result), do: result
end
