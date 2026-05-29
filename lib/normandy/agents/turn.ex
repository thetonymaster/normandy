defmodule Normandy.Agents.Turn do
  @moduledoc """
  The pure finite-state-machine core of an agent turn.

  A turn is plain data (`Normandy.Agents.Turn.State`) advanced by `step/2`, a
  pure function: `step(state, event) -> {state', [effect]}`. It performs no I/O.
  Events come from the shell (LLM responses, tool results, errors); effects are
  data the shell interprets (call the LLM, dispatch tools, append to memory,
  emit telemetry, finalize, fail). Keeping the core pure makes every transition
  unit/property testable without processes, and makes the state serializable for
  the durable/suspendable shells added in later phases.

  ## States

  Seven statuses are defined; this phase exercises five. `:awaiting_approval`
  (suspend/resume, Phase 4) and `:steering` as a *resting* state with compaction
  (Phase 5) are reserved in the type but not yet entered — the current loop does
  not rest at a steering point, so the tool-results transition passes through it
  as an emitted event only (see `step/2` on `:tool_dispatch`).
  """

  alias Normandy.Agents.Turn.State

  defmodule State do
    @moduledoc "Serializable data for one in-flight turn (the design's `%TurnState{}`)."

    @type status ::
            :provisioning
            | :assistant_streaming
            | :tool_dispatch
            | :awaiting_approval
            | :steering
            | :stopped
            | :failed

    @type t :: %__MODULE__{
            status: status(),
            max_iterations: pos_integer(),
            iterations_left: integer(),
            awaiting_final: boolean(),
            response_model: term(),
            output_schema: term(),
            pending_calls: [term()],
            last_response: term() | nil,
            final_response: term() | nil,
            stop_reason: :completed | :max_iterations | nil,
            error: term() | nil
          }

    defstruct status: :provisioning,
              max_iterations: 5,
              iterations_left: 5,
              awaiting_final: false,
              response_model: nil,
              output_schema: nil,
              pending_calls: [],
              last_response: nil,
              final_response: nil,
              stop_reason: nil,
              error: nil
  end

  @doc """
  Builds the initial `:provisioning` state for a turn.

  Options: `:max_iterations` (default 5), `:response_model` (the response model
  for normal tool-loop LLM calls, e.g. `%ToolCallResponse{}`), `:output_schema`
  (the response model for the forced final call when the iteration cap is hit).
  """
  @spec new(keyword()) :: State.t()
  def new(opts \\ []) do
    max = Keyword.get(opts, :max_iterations, 5)

    %State{
      status: :provisioning,
      max_iterations: max,
      iterations_left: max,
      response_model: Keyword.get(opts, :response_model),
      output_schema: Keyword.get(opts, :output_schema)
    }
  end

  @doc """
  Advances the turn one event. Pure: returns `{state', [effect]}` and does no I/O.
  """
  @spec step(State.t(), term()) :: {State.t(), [tuple()]}
  def step(%State{status: :provisioning} = s, :start) do
    {%{s | status: :assistant_streaming},
     [
       {:emit_event, :iteration,
        %{iteration: s.max_iterations - s.iterations_left + 1, iterations_left: s.iterations_left}},
       {:call_llm, %{response_model: s.response_model, final: false}}
     ]}
  end

  def step(%State{status: :assistant_streaming} = s, {:llm_response, resp}) do
    case tool_calls(resp) do
      [] ->
        {%{
           s
           | status: :stopped,
             last_response: resp,
             final_response: resp,
             stop_reason: :completed
         }, [{:append_message, "assistant", resp}, {:finalize, resp}]}

      calls ->
        {%{s | status: :tool_dispatch, last_response: resp, pending_calls: calls},
         [{:append_message, "assistant", resp}, {:dispatch_tools, calls}]}
    end
  end

  def step(%State{status: :tool_dispatch} = s, {:tool_results, results}) do
    new_left = s.iterations_left - 1
    append_effects = Enum.map(results, fn r -> {:append_message, "tool", r} end)
    steering = {:emit_event, :steering, %{iterations_left: new_left}}

    if new_left <= 0 do
      # Iteration cap reached: one forced final call against the output schema,
      # then finalize regardless of tool calls (see :assistant_streaming +
      # awaiting_final in Task 5). `:steering` is where compaction will hook in
      # Phase 5; today it is only an emitted boundary event, not a resting state.
      {%{
         s
         | status: :assistant_streaming,
           awaiting_final: true,
           iterations_left: new_left,
           pending_calls: []
       },
       append_effects ++ [steering, {:call_llm, %{response_model: s.output_schema, final: true}}]}
    else
      iteration =
        {:emit_event, :iteration,
         %{iteration: s.max_iterations - new_left + 1, iterations_left: new_left}}

      {%{s | status: :assistant_streaming, iterations_left: new_left, pending_calls: []},
       append_effects ++
         [steering, iteration, {:call_llm, %{response_model: s.response_model, final: false}}]}
    end
  end

  defp tool_calls(%{tool_calls: nil}), do: []
  defp tool_calls(%{tool_calls: calls}) when is_list(calls), do: calls
  defp tool_calls(_), do: []
end
