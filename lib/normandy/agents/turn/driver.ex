defmodule Normandy.Agents.Turn.Driver do
  @moduledoc """
  Generic synchronous interpreter for the pure `Normandy.Agents.Turn` core.

  Drives a turn to a stop by feeding `:start` into `Turn.step/2`, performing each
  returned effect via an injected `%Handlers{}` set, and feeding the resulting
  event back into `step/2` until the turn reaches a terminal effect. The driver
  owns FSM stepping and `acc` threading; the handlers own all side effects (LLM
  calls, tool dispatch, memory, guards, telemetry) and return the updated `acc`.

  `acc` is opaque to the driver — the production shells pass the running
  `%BaseAgentConfig{}` (the memory accumulator). This lets one driver serve the
  non-streaming and streaming production paths (and future shells) with different
  handler sets, the same way `Turn.Inline` serves the test/library path.

  By design, `step/2` always places the single blocking/terminal effect last in
  its effect list, so the driver performs the leading `:emit_event` /
  `:append_message` effects in order, then acts on the terminal one.
  """

  alias Normandy.Agents.Turn

  defmodule Handlers do
    @moduledoc "The injected side-effecting functions the driver consults per effect."

    @type acc :: term()
    @type t :: %__MODULE__{
            call_llm: (acc(), Turn.State.t(), map() -> term()),
            dispatch_tools: (acc(), [term()] -> [term()]),
            convert: (acc(), term(), term() -> term()),
            validate: (acc(), term() -> term()),
            guard: (acc(), term() -> any()),
            append: (acc(), String.t(), term() -> acc()),
            compact: (acc(), Turn.State.t(), map() -> {acc(), map()}),
            emit: (acc(), atom(), map() -> any())
          }
    defstruct [:call_llm, :dispatch_tools, :convert, :validate, :guard, :append, :compact, :emit]
  end

  @spec drive(Turn.State.t(), Handlers.t(), term()) :: {term(), Turn.State.t()}
  def drive(%Turn.State{} = state, %Handlers{} = handlers, acc) do
    {state, effects} = Turn.step(state, :start)
    run(acc, state, effects, handlers)
  end

  defp run(acc, state, [], _handlers), do: {acc, state}

  defp run(acc, state, [effect | rest], handlers) do
    case effect do
      {:emit_event, name, meta} ->
        handlers.emit.(acc, name, meta)
        run(acc, state, rest, handlers)

      {:append_message, role, content} ->
        run(handlers.append.(acc, role, content), state, rest, handlers)

      {:call_llm, request} ->
        response = handlers.call_llm.(acc, state, request)
        advance(acc, state, {:llm_response, response}, handlers)

      {:dispatch_tools, calls} ->
        results = handlers.dispatch_tools.(acc, calls)
        advance(acc, state, {:tool_results, results}, handlers)

      {:maybe_compact, info} ->
        {acc2, meta} = handlers.compact.(acc, state, info)
        advance(acc2, state, {:compaction_done, meta}, handlers)

      {:convert_output, raw, output_schema} ->
        advance(
          acc,
          state,
          {:output_converted, handlers.convert.(acc, raw, output_schema)},
          handlers
        )

      {:validate_output, value} ->
        advance(acc, state, {:output_validated, handlers.validate.(acc, value)}, handlers)

      {:guard_output, value} ->
        handlers.guard.(acc, value)
        advance(acc, state, {:output_guarded, value}, handlers)

      {:finalize, _value} ->
        {acc, state}

      {:fail, reason} ->
        raise "Turn FSM reached :failed unexpectedly: #{inspect(reason)}"
    end
  end

  defp advance(acc, state, event, handlers) do
    {state, effects} = Turn.step(state, event)
    run(acc, state, effects, handlers)
  end
end
