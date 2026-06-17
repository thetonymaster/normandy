defmodule Normandy.Guardrails do
  @moduledoc """
  Runs a list of `Normandy.Guardrails.Guard` modules against a value.

  Guardrails sit between schema validation (shape) and resilience (transport)
  and express **content-level constraints** — length limits, forbidden phrases,
  regex allow/deny lists, required output fields, and so on.

  Each entry in the guard list is either a bare module atom or a
  `{module, opts}` tuple. Guards run in order and short-circuit on the first
  failure: guardrails model blocking policy, not aggregate reporting.

  ## Example

      iex> alias Normandy.Guardrails
      iex> alias Normandy.Guardrails.Builtins.MaxLength
      iex> Guardrails.run([{MaxLength, limit: 5}], "too long")
      {:error, [%{guard: MaxLength, path: [], message: _, constraint: :max_length}]}

      iex> Guardrails.run([{MaxLength, limit: 100}], "ok")
      {:ok, "ok"}

  Attach a guard list to an agent by setting `:input_guardrails` or
  `:output_guardrails` on `Normandy.Agents.BaseAgentConfig`, or via the
  `guardrails/2` macro in `Normandy.DSL.Agent`.

  ## Pre-charge admission

  Input guardrails run inside a turn by default and signal a rejection by
  raising. To use them as a **pre-charge filter** — block disallowed input
  before paying for a turn — call `Normandy.Agents.BaseAgent.admit/2,3`, which
  runs `run/2,3` with no turn, memory, or circuit breaker and returns
  `:ok | {:block, violations}` instead of raising.

  ## Context

  `run/3` threads a caller-supplied `context` map to any guard implementing the
  optional `Guard.check/3` callback (guards with only `check/2` are unaffected).
  Context carries host data a guard needs but the framework must not interpret —
  ids, locale, conversation history. See `Normandy.Guardrails.Builtins.SemanticScope`
  for a guard that uses it.

  ## Error handling (`:on_error`)

  Each guard spec may carry an `:on_error` policy controlling what happens when
  its `check` **raises**:

  - `:reraise` (default) — the exception propagates. A configuration bug stays a
    crash, not a silent admit.
  - `:open` — the crash is rescued and treated as a pass. Use this for a guard
    that calls an external service so an outage admits instead of taking down
    the whole guard chain.
  - `:closed` — the crash is rescued and turned into a `:guard_error` violation.

  Only the guard's `check` call is rescued; a malformed return value is a
  contract violation and always raises regardless of `:on_error`.

  ## Structured reason

  A violation's `:constraint` (an atom) is the machine-readable rejection
  reason. Hosts map it to localized copy or routing — e.g. a guard returning
  `constraint: :off_topic` lets the caller render scope-specific messaging
  without parsing strings. Extra keys on the violation map are allowed.

  ## Streaming

  Input guardrails run on streaming entry points (`BaseAgent.stream_response/3`,
  `BaseAgent.stream_with_tools/3`) before the LLM call — violations raise the
  same as non-streaming paths.

  Output guardrails run on streaming in one of two modes, configured per agent:

  - `:accumulate` (default) — guards run on the **concatenated assistant text**
    (text blocks from the streamed response, joined) after the stream
    completes. Log-and-continue on violation; content has already reached the
    caller. This differs from the non-streaming path, which guards the
    validated schema struct — streaming never produces one, so field-targeting
    guards (e.g. `{ForbiddenSubstrings, field: :summary}`) do not apply in
    streaming mode. Use bare string guards (no `:field`) for streaming output.

  - `:incremental` — guards run every `:output_guardrails_chunk_size` bytes of
    accumulated assistant text. On violation, the stream is halted, a
    `:guardrail_violation` event is emitted to the caller callback, any
    partial tool-use block is dropped, and the returned response carries
    `:guardrail_violations`. Follows NVIDIA NeMo Guardrails' chunking approach.

  `RequiredFields` is terminal-only and does not apply to either streaming
  mode (no schema struct to inspect).

  Both modes populate the `:guardrail_violations` field on the returned
  response (list, empty on pass) and emit the
  `[:normandy, :agent, :guardrail, :violation]` telemetry event with metadata
  `streaming: true` and `mode: :accumulate | :incremental`.

  ## Telemetry

  A `[:normandy, :agent, :guardrail, :violation]` event is emitted per
  violation batch. One event per final-response emission, not per user turn —
  with `enable_json_retry` plus retries, a single turn can emit multiple
  output-guardrail events. Metadata includes the matched `:term` / `:pattern`
  on the violation payload; redact downstream if your block-list is sensitive.

  `Normandy.Agents.BaseAgent.admit/2,3` additionally emits
  `[:normandy, :agent, :guardrail, :decision]` with `outcome` in
  `:admit | :block | :error`, so hosts can monitor admit/block/false-positive
  rates on one stream. The in-turn input path emits it too (it delegates to
  `admit/2`); it is suppressed when no guardrails are configured.
  """

  alias Normandy.Guardrails.Guard

  @type spec :: module() | {module(), keyword()}

  @doc """
  Runs the guard list against `value`.

  Returns `{:ok, value}` if every guard passes, or `{:error, [violation]}` as
  soon as one fails. An empty guard list is always `{:ok, value}`.
  """
  @spec run([spec()], term()) :: {:ok, term()} | {:error, [Guard.violation()]}
  def run(guards, value), do: run(guards, value, %{})

  @doc """
  Runs the guard list against `value`, threading `context` to guards.

  Behaves exactly like `run/2`, additionally passing the `context` map to any
  guard that implements the optional `Guard.check/3` callback. Guards that
  implement only `check/2` never see the context and their `opts` are
  unchanged — `run/2` is `run(guards, value, %{})`, so this is purely additive.

  Returns `{:ok, value}` if every guard passes, or `{:error, [violation]}` as
  soon as one fails. An empty guard list is always `{:ok, value}`.
  """
  @spec run([spec()], term(), map()) :: {:ok, term()} | {:error, [Guard.violation()]}
  def run([], value, _context), do: {:ok, value}

  def run(guards, value, context) when is_list(guards) and is_map(context) do
    Enum.reduce_while(guards, {:ok, value}, fn spec, {:ok, v} ->
      {mod, opts} = normalize(spec)

      case invoke(mod, v, opts, context) do
        :ok ->
          {:cont, {:ok, v}}

        {:error, violations} when is_list(violations) ->
          {:halt, {:error, violations}}

        other ->
          raise ArgumentError,
                "expected #{inspect(mod)}.check/2 to return :ok or {:error, [violation]}, got: #{inspect(other)}"
      end
    end)
  end

  # Invokes the guard under its `:on_error` policy. `:reraise` (default) lets a
  # crashing guard propagate — a config bug stays a crash, not a silent admit.
  # `:open` rescues and treats the crash as a pass; `:closed` rescues and turns
  # it into a `:guard_error` violation. Only the `check` call is rescued: a
  # malformed return is a contract violation handled by the caller, not an
  # `:on_error` case.
  defp invoke(mod, value, opts, context) do
    case Keyword.get(opts, :on_error, :reraise) do
      :reraise ->
        do_check(mod, value, opts, context)

      policy when policy in [:open, :closed] ->
        try do
          do_check(mod, value, opts, context)
        rescue
          exception -> on_error_result(policy, mod, exception)
        end

      other ->
        raise ArgumentError,
              "invalid :on_error for #{inspect(mod)}: expected :reraise, :open, or " <>
                ":closed, got: #{inspect(other)}"
    end
  end

  # Dispatches to the guard's check/3 when it implements the optional context
  # arity, otherwise its check/2. Context-unaware guards are invoked exactly as
  # before.
  defp do_check(mod, value, opts, context) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :check, 3) do
      mod.check(value, opts, context)
    else
      mod.check(value, opts)
    end
  end

  defp on_error_result(:open, _mod, _exception), do: :ok

  defp on_error_result(:closed, mod, exception) do
    {:error,
     [
       %{
         guard: mod,
         path: [],
         message: "guard #{inspect(mod)} crashed: #{Exception.message(exception)}",
         constraint: :guard_error
       }
     ]}
  end

  defp normalize(mod) when is_atom(mod), do: {mod, []}
  defp normalize({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}

  defp normalize(other) do
    raise ArgumentError,
          "invalid guard spec: expected module or {module, opts}, got: #{inspect(other)}"
  end
end
