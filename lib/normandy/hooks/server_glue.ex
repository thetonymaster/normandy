defmodule Normandy.Hooks.ServerGlue do
  @moduledoc false
  # Turn.Server's hook logic, so server.ex keeps one-line call sites. Every call the
  # server makes into hook code goes through its call_handler/3 (worker_hook/3 in the
  # worker task), so no hook outcome terminates the server.

  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Driver
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Hooks.Handlers, as: HookHandlers
  alias Normandy.Hooks.Runner

  @doc """
  The `on_turn_end` outcome of a failed turn: an output-guardrail block stays a rejection;
  any other reason is `{:error, exception}`, the exception `run/2` replies.
  """
  @spec fail_outcome(term()) :: Normandy.Behaviours.Hooks.outcome()
  def fail_outcome({:rejected, exception}), do: {:rejected, exception}
  def fail_outcome(reason), do: {:error, Normandy.TurnError.from_reason(reason)}

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
  Runs `before_llm` for one LLM call: `Normandy.Hooks.Handlers` wrapped around the
  server's `handlers` with a `call_llm` that does nothing, so the server calls the LLM
  apart from it and can tell a hook's crash from the client's. Returns `:ok`; a halt
  raises `Normandy.HookHaltError`.
  """
  @spec before_llm(Driver.Handlers.t(), map(), Turn.State.t(), map()) :: :ok
  def before_llm(handlers, config, state, request) do
    %{handlers | call_llm: fn _config, _state, _request -> :ok end}
    |> HookHandlers.wrap(config)
    |> then(& &1.call_llm.(config, state, request))
  end

  @doc """
  Runs `after_compact` on a finished compaction (`compacted`, the compact handler's
  `{config, meta}`): `Normandy.Hooks.Handlers` wrapped around the server's `handlers` with
  a `compact` that returns it, so a hook's crash is told apart from the compactor's.
  Returns `{config, meta}` with any injected texts in the config's memory.
  """
  @spec after_compact(Driver.Handlers.t(), map(), Turn.State.t(), map(), {map(), map()}) ::
          {map(), map()}
  def after_compact(handlers, config, state, info, compacted) do
    %{handlers | compact: fn _config, _state, _info -> compacted end}
    |> HookHandlers.wrap(config)
    |> then(& &1.compact.(config, state, info))
  end

  @doc """
  Runs `after_tool` on a result the server built (an interrupted result). `call` may be a
  raw tool-call map; the result answers its id.
  """
  @spec after_tool(map(), ToolCall.t() | map(), ToolResult.t()) :: ToolResult.t()
  def after_tool(config, call, %ToolResult{} = result) do
    if Runner.handles?(config, :after_tool) do
      call = Dispatch.to_tool_call(call)

      Dispatch.finish(config, call, %{
        Runner.after_tool(config, call, result)
        | tool_call_id: call.id
      })
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
       when is_map_key(by_id, id) do
    call = Map.fetch!(by_id, id)
    Dispatch.finish(config, call, %{Runner.after_tool(config, call, result) | tool_call_id: id})
  end

  defp answer_built(_config, _by_id, result), do: result
end
