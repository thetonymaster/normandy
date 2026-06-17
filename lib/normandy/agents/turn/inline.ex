defmodule Normandy.Agents.Turn.Inline do
  @moduledoc """
  Inline (synchronous) interpreter for the pure `Normandy.Agents.Turn` core.

  Drives a turn to completion in the calling process: it feeds `:start` into
  `Turn.step/2`, performs each returned effect's side-effect, and feeds the
  resulting event back into `step/2` until the turn reaches `:stopped` (returns
  `{:ok, state}`) or `:failed` (returns `{:error, reason, state}`).

  This is the library / scripted-run shell. It does NOT (yet) replace
  `BaseAgent.run/2`; it exists to prove the FSM core runs a real turn against a
  real `Dispatch` chokepoint. Compaction at the `:steering` boundary is
  supported via the optional `:compact` dep (default no-op); streaming,
  guardrails, validation, persistence and approval shells come in later phases.

  `deps` is a map of side-effecting functions:
    * `:call_llm` — `fn request -> {:ok, response} | {:error, reason} end` (required)
    * `:dispatch` — `fn calls -> [%ToolResult{}] end` (required)
    * `:append`   — `fn role, content -> any end` (optional, defaults to no-op)
    * `:emit`     — `fn name, meta -> any end` (optional, defaults to no-op)
    * `:convert`  — `fn raw, response_model -> converted end` (optional, defaults to identity:
                    returns `raw` unchanged)
    * `:validate` — `fn value -> validated end` (optional, defaults to identity: returns `value`
                    unchanged)
    * `:guard`    — `fn value -> any end` (optional, defaults to no-op: side-effecting, return
                    is ignored and the input `value` is fed forward via `{:output_guarded, value}`)
    * `:compact`  — `fn info -> any end` (optional, defaults to no-op). Invoked at the
                    `:steering` boundary; the inline shell does not thread memory, so
                    a real impl must compact external state by side effect.

  By design, `step/2` always places the single blocking/terminal effect
  (`:call_llm`, `:dispatch_tools`, `:finalize`, `:fail`) last in its effect list,
  so the interpreter performs the leading `:append_message` / `:emit_event`
  effects in order and then acts on the terminal one.
  """

  alias Normandy.Agents.Turn

  @spec run(Turn.State.t(), map()) :: {:ok, Turn.State.t()} | {:error, term(), Turn.State.t()}
  def run(%Turn.State{} = state, deps) do
    deps =
      Map.merge(
        %{
          emit: fn _name, _meta -> :ok end,
          append: fn _role, _content -> :ok end,
          convert: fn raw, _response_model -> raw end,
          validate: fn value -> value end,
          guard: fn _value -> :ok end,
          compact: fn _info -> :ok end
        },
        deps
      )

    {state, effects} = Turn.step(state, :start)
    process(state, effects, deps)
  end

  defp process(state, [], _deps), do: {:ok, state}

  defp process(state, [effect | rest], deps) do
    case effect do
      {:emit_event, name, meta} ->
        deps.emit.(name, meta)
        process(state, rest, deps)

      {:append_message, role, content} ->
        deps.append.(role, content)
        process(state, rest, deps)

      {:call_llm, request} ->
        case deps.call_llm.(request) do
          {:ok, response} -> advance(state, {:llm_response, response}, deps)
          {:error, reason} -> advance(state, {:llm_error, reason}, deps)
        end

      {:dispatch_tools, calls} ->
        results = deps.dispatch.(calls)
        advance(state, {:tool_results, results}, deps)

      {:maybe_compact, info} ->
        deps.compact.(info)
        advance(state, {:compaction_done, %{}}, deps)

      {:convert_output, raw, response_model} ->
        converted = deps.convert.(raw, response_model)
        advance(state, {:output_converted, converted}, deps)

      {:validate_output, value} ->
        validated = deps.validate.(value)
        advance(state, {:output_validated, validated}, deps)

      {:guard_output, value} ->
        deps.guard.(value)
        advance(state, {:output_guarded, value}, deps)

      {:finalize, _response} ->
        {:ok, state}

      {:fail, reason} ->
        {:error, reason, state}
    end
  end

  defp advance(state, event, deps) do
    {state, effects} = Turn.step(state, event)
    process(state, effects, deps)
  end
end
