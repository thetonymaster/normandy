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

  Seven statuses are defined. `:awaiting_approval` (suspend/resume for human
  approval) is entered when a dispatched batch parks calls. `:steering` is a
  resting state entered at every tool-batch boundary: the core emits a
  `{:maybe_compact, info}` effect there and resumes on `{:compaction_done, _}`,
  which is where context-window compaction (Phase 5) runs in the shell.
  """

  alias Normandy.Agents.Turn.State
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  defmodule State do
    @moduledoc "Serializable data for one in-flight turn (the design's `%TurnState{}`)."

    @type status ::
            :provisioning
            | :assistant_streaming
            | :tool_dispatch
            | :finalizing
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
            parked_calls: [term()],
            held_results: [term()],
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
              parked_calls: [],
              held_results: [],
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

  Raises `ArgumentError` if `:max_iterations` is not an integer >= 1, enforcing
  the `pos_integer()` contract on `State.max_iterations` (mirrors the check
  `BaseAgent.init/1` applies at the shell boundary).
  """
  @spec new(keyword()) :: State.t()
  def new(opts \\ []) do
    max = Keyword.get(opts, :max_iterations, 5)

    unless is_integer(max) and max >= 1 do
      raise ArgumentError, ":max_iterations must be an integer >= 1, got: #{inspect(max)}"
    end

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

  def step(%State{status: :assistant_streaming, awaiting_final: true} = s, {:llm_response, resp}) do
    {%{
       s
       | status: :finalizing,
         awaiting_final: false,
         last_response: resp,
         stop_reason: :max_iterations
     }, [{:validate_output, resp}]}
  end

  def step(%State{status: :assistant_streaming} = s, {:llm_response, resp}) do
    case tool_calls(resp) do
      [] ->
        s = %{s | status: :finalizing, last_response: resp, stop_reason: :completed}

        if convert_needed?(s) do
          {s, [{:convert_output, resp, s.output_schema}]}
        else
          {s, [{:validate_output, resp}]}
        end

      calls ->
        {%{s | status: :tool_dispatch, last_response: resp, pending_calls: calls},
         [{:append_message, "assistant", resp}, {:dispatch_tools, calls}]}
    end
  end

  def step(%State{status: :finalizing} = s, {:output_converted, converted}) do
    {s, [{:validate_output, converted}]}
  end

  def step(%State{status: :finalizing} = s, {:output_validated, validated}) do
    {s, [{:guard_output, validated}]}
  end

  def step(%State{status: :finalizing} = s, {:output_guarded, value}) do
    {%{s | status: :stopped, final_response: value},
     [{:append_message, "assistant", value}, {:finalize, value}]}
  end

  def step(%State{status: :tool_dispatch} = s, {:tool_results, results}) do
    apply_tool_results(s, results)
  end

  # Compaction (or its no-op) finished. Resolve the steering boundary. At/after
  # the iteration cap, issue the forced-final call (skipping convert, like the old
  # path); otherwise emit the next :iteration and continue. iterations_left was
  # already decremented in apply_tool_results.
  def step(%State{status: :steering, iterations_left: left} = s, {:compaction_done, _meta})
      when left <= 0 do
    {%{s | status: :assistant_streaming, awaiting_final: true},
     [{:call_llm, %{response_model: s.output_schema, final: true}}]}
  end

  def step(%State{status: :steering} = s, {:compaction_done, _meta}) do
    iteration =
      {:emit_event, :iteration,
       %{iteration: s.max_iterations - s.iterations_left + 1, iterations_left: s.iterations_left}}

    {%{s | status: :assistant_streaming},
     [iteration, {:call_llm, %{response_model: s.response_model, final: false}}]}
  end

  # Some calls in the batch need human approval. The shell has already executed the
  # allowed calls and passes their `held` results plus the `parked` calls. Park:
  # store both (the persisted state carries them, so resume needs no re-execution),
  # persist the suspend state, then emit the awaiting-approval event. Results are
  # NOT appended yet — the whole batch's tool_results must go to the model
  # together (later tasks).
  def step(%State{status: :tool_dispatch} = s, {:needs_approval, held, parked}) do
    s2 = %{s | status: :awaiting_approval, held_results: held, parked_calls: parked}
    # Persist BEFORE announcing the park: an observer that sees `:awaiting_approval`
    # is then guaranteed the resumable state is durable, and a persist failure fails
    # the turn without ever signalling the park (honouring the suspend-point hard
    # gate). The Driver never reaches this branch (it never parks), so the order is
    # immaterial to the inline path.
    {s2, [{:persist, s2}, {:emit_event, :awaiting_approval, %{parked: length(parked)}}]}
  end

  # Once a partial approval clears parked_calls (some approved → shell is running
  # them, awaiting :approved_results), a retried/duplicate {:approval, _} must not
  # re-enter the resolve clause below: with parked == [] it would apply only
  # held_results, drop the still-executing approved result, and decrement the batch
  # early (violating the batch-completeness contract). Surface it as :failed — a
  # shell sequencing bug, consistent with the total-function fallback.
  def step(%State{status: :awaiting_approval, parked_calls: []} = s, {:approval, _decisions}) do
    reason = {:unexpected_event, :awaiting_approval, :approval_without_parked_calls}
    {%{s | status: :failed, error: reason}, [{:fail, reason}]}
  end

  # Human approval decisions arrive (tool_call_id => :approve | :reject). Anything
  # not explicitly :approve is rejected (fail-closed). Build denials for rejects;
  # if none are approved, finish the batch now (held ++ denials, reordered to the
  # original tool_use order). If some are approved, stash the denials and ask the
  # shell to run the approved calls (no re-classify — a later task applies the merge).
  def step(
        %State{status: :awaiting_approval, parked_calls: parked, held_results: held} = s,
        {:approval, decisions}
      ) do
    {approved, rejected} =
      Enum.split_with(parked, fn %ToolCall{id: id} -> Map.get(decisions, id) == :approve end)

    rejected_results = Enum.map(rejected, &rejection_result/1)

    case approved do
      [] ->
        apply_tool_results(s, reorder(held ++ rejected_results, s.pending_calls))

      _ ->
        # status deliberately stays :awaiting_approval — the shell runs the approved
        # calls, then feeds :approved_results back (handled by a later clause).
        s2 = %{s | parked_calls: [], held_results: held ++ rejected_results}
        {s2, [{:execute_approved, approved}]}
    end
  end

  # The shell finished running the approved calls. Merge their results with the
  # held (allowed + rejected) results, reorder to the original batch order, and
  # apply the complete batch — decrementing the iteration counter exactly once.
  def step(
        %State{status: :awaiting_approval, held_results: held} = s,
        {:approved_results, results}
      ) do
    apply_tool_results(s, reorder(held ++ results, s.pending_calls))
  end

  def step(%State{status: status} = s, {:llm_error, reason})
      when status not in [:stopped, :failed] do
    {%{s | status: :failed, error: reason}, [{:fail, reason}]}
  end

  def step(%State{status: status} = s, {:tool_error, reason})
      when status not in [:stopped, :failed] do
    {%{s | status: :failed, error: reason}, [{:fail, reason}]}
  end

  def step(%State{status: status} = s, _event) when status in [:stopped, :failed] do
    {s, []}
  end

  # Total function: an unexpected (state, event) pair surfaces as :failed rather
  # than crashing the shell, with enough context to debug. Reaching this is a bug
  # in the shell's event sequencing, not normal flow.
  def step(%State{status: status} = s, event) do
    reason = {:unexpected_event, status, event}
    {%{s | status: :failed, error: reason}, [{:fail, reason}]}
  end

  @doc """
  Re-derives the effects to continue a turn from a **persisted, non-terminal**
  state (used by an eager shell after passivation/handoff). Pure.

  Only states the core persists are resumable: `:steering` (per-batch boundary)
  re-issues compaction then continues; `:awaiting_approval` waits for a decision
  (no effects). Terminal states yield no effects.
  """
  @spec resume(State.t()) :: {State.t(), [tuple()]}
  def resume(%State{status: :steering, iterations_left: left} = s) do
    {s, [{:maybe_compact, %{iterations_left: left}}]}
  end

  def resume(%State{status: :awaiting_approval} = s), do: {s, []}
  def resume(%State{status: status} = s) when status in [:stopped, :failed], do: {s, []}

  # Any other persisted status is not a durable resume point; surface as failed so
  # an eager shell does not silently hang on an unresumable state.
  def resume(%State{} = s) do
    reason = {:unresumable_state, s.status}
    {%{s | status: :failed, error: reason}, [{:fail, reason}]}
  end

  # The batch-results transition, shared by the normal `:tool_dispatch` path and
  # the approval-resume paths. Appends each result, decrements the iteration
  # counter exactly once per batch, emits the steering boundary event, then parks
  # in `:steering` and asks the shell to (maybe) compact before the next LLM call.
  # The continue-vs-forced-final decision is deferred to the `:compaction_done`
  # clauses below. Always clears the per-batch scratch fields (`pending_calls`,
  # `parked_calls`, `held_results`); on the normal path the latter two are empty.
  defp apply_tool_results(%State{} = s, results) do
    new_left = s.iterations_left - 1
    append_effects = Enum.map(results, fn r -> {:append_message, "tool", r} end)
    steering = {:emit_event, :steering, %{iterations_left: new_left}}

    s2 = %{
      s
      | status: :steering,
        iterations_left: new_left,
        pending_calls: [],
        parked_calls: [],
        held_results: []
    }

    {s2,
     append_effects ++ [steering, {:persist, s2}, {:maybe_compact, %{iterations_left: new_left}}]}
  end

  # Reorder a merged result list to match the original batch (`pending_calls`) by
  # tool_call_id, so the next user turn presents tool_result blocks in API order.
  defp reorder(results, pending_calls) do
    index =
      pending_calls
      |> Enum.with_index()
      |> Map.new(fn {%ToolCall{id: id}, i} -> {id, i} end)

    Enum.sort_by(results, fn %ToolResult{tool_call_id: id} ->
      Map.get(index, id, length(pending_calls))
    end)
  end

  # Denial result for a parked call the approver rejected (or never decided).
  defp rejection_result(%ToolCall{id: id}) do
    %ToolResult{
      tool_call_id: id,
      output: %{error: "tool call rejected by approver", denied: true, pending_approval: false},
      is_error: true
    }
  end

  defp tool_calls(%{tool_calls: nil}), do: []
  defp tool_calls(%{tool_calls: calls}) when is_list(calls), do: calls
  defp tool_calls(_), do: []

  # Conversion (the ToolCallResponse -> output_schema unwrap) is needed only when
  # the turn's normal-call response model differs from the output schema — i.e.
  # the tool-loop case, where the LLM was asked for %ToolCallResponse{}. A
  # no-tools turn sets response_model == output_schema and skips conversion,
  # matching run_without_tools. The forced-final (:max_iterations) path skips
  # conversion structurally (see the awaiting_final clause).
  defp convert_needed?(%State{response_model: rm, output_schema: os}), do: rm != os
end
