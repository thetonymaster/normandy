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

      alias Normandy.Guardrails
      alias Normandy.Guardrails.Builtins.MaxLength
      Guardrails.run([{MaxLength, limit: 5}], "too long")
      #=> {:error, [%{guard: MaxLength, path: [], message: _, constraint: :max_length}]}

      Guardrails.run([{MaxLength, limit: 100}], "ok")
      #=> {:ok, "ok"}

  Attach a guard list to an agent with `guardrails: [input: ..., output: ...]` in
  `Normandy.Agents.BaseAgent.init/1`, or with the `guardrails/2` macro in
  `Normandy.DSL.Agent`.

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
  its `check` **crashes**: raises, exits (a `GenServer.call` or `Task.await` timeout
  inside the guard) or throws:

  - `:reraise` (default) — the crash propagates. A configuration bug stays a
    crash, not a silent admit.
  - `:open` — the crash is caught and treated as a pass. Use this for a guard
    that calls an external service so an outage admits instead of taking down
    the whole guard chain.
  - `:closed` — the crash is caught and turned into a `:guard_error` violation
    whose message names the guard and the exception's module, the exit's tag or
    "threw", never the exception's message or the exit's terms.

  Only the guard's `check` call is caught; a malformed return value is a
  contract violation and always raises regardless of `:on_error`. So does a
  built-in guard's configuration error (an `ArgumentError` or `KeyError`, such
  as a `:field` the struct does not have or a missing option). Host code a built-in
  guard calls (`SemanticScope`'s `:classifier` and `:fast_path`) is not configuration:
  its crash reaches `:on_error` as a `Normandy.Guardrails.GuardError`. A guard has no
  timeout of its own: one that blocks without failing blocks the turn, so give the
  service call inside it a timeout. A `:field` on a plain map cannot be checked: a map
  has no fixed keys, so a missing key reads as `nil`.

  ## What an input guard receives

  An input guard receives the validated input: a `%BaseAgentInputSchema{}` for the default
  schema (whether the caller passed `"text"` or `%{chat_message: "text"}`), or the custom
  schema's struct. A built-in guard with no `:field` option checks the `chat_message` text of
  a default-schema input; with `field: :chat_message` it reads that field of the struct.
  `SemanticScope` classifies that text too. `RequiredFields` checks named fields, so it stays on
  the struct.

  ## Structured reason

  A violation's `:constraint` (an atom) is the machine-readable rejection
  reason. Hosts map it to localized copy or routing — e.g. a guard returning
  `constraint: :off_topic` lets the caller render scope-specific messaging
  without parsing strings. Extra keys on the violation map are allowed.

  ## Output violations (`guardrails: [on_violation: ...]`)

  On the non-streaming path (`BaseAgent.run/3`, `Turn.Server`), output guards
  run on the validated answer before it is saved to memory:

  - `:block` (default) — `run` returns
    `{:error, %Normandy.Guardrails.ViolationError{}}` (`run!` raises it;
    `Turn.Server.run/2` replies the same `{:error, exception}`) and the
    answer is not saved.
  - `:warn` — the violation is logged and the answer is returned and saved. The
    warning names the guards, the paths and the count
    (`Agent output guardrail violation: ForbiddenSubstrings at chat_message (1 violation)`),
    never the messages, which quote the guard's configuration (a forbidden term, a
    pattern). Neither the log nor telemetry carries them: only the caller's reply does
    (the `ViolationError` under `:block`, the `:guardrail_violation` stream event).

  The option does not apply to streaming, where the content has already
  reached the caller (see below).

  ## Streaming

  Input guardrails run on `BaseAgent.stream/3` before the LLM call, as on
  `BaseAgent.run/3`: a violation returns `{:error, %Normandy.Guardrails.ViolationError{}}`.

  Output guardrails run on streaming in one of two modes, configured per agent:

  - `:accumulate` (default) — guards run on the **concatenated assistant text**
    (text blocks from the streamed response, joined) after the stream
    completes. A violation is logged and reported through a
    `%Normandy.Components.StreamEvent{type: :guardrail_violation}` and telemetry,
    not blocked: the content has already reached the caller. This differs from the
    non-streaming path, which guards the validated schema struct: streaming guards
    the text before it is converted, so field-targeting guards (e.g.
    `{ForbiddenSubstrings, field: :summary}`) do not apply in streaming mode. Use
    bare string guards (no `:field`) for streaming output.

  - `:incremental` — guards run every `guardrails[:chunk_size]` bytes of
    accumulated assistant text. On violation, the stream is halted, a
    `:guardrail_violation` event is emitted to the caller callback and telemetry,
    and any partial tool-use block is dropped; the text streamed so far is
    converted to the output schema: a `:chat_message` schema gets that text; for a
    non-chat schema, partial text that does not parse into it makes `stream/3` return
    `{:error, %Normandy.LLMError{type: :invalid_output}}`. Follows NVIDIA NeMo
    Guardrails' chunking approach.

    Each check runs the guards on the **whole** text accumulated so far, not on the
    new chunk, so a pattern that spans two chunks is still seen. The cost grows with
    the square of the answer's length: an answer of `n` bytes is checked about
    `n / chunk_size` times on texts up to `n` bytes long (a 100_000-byte answer with
    the default `chunk_size: 200` runs the guards about 500 times, on 50_000 bytes on
    average). For long answers or guards that are slow or call a service, raise
    `chunk_size` or use `:accumulate`.

  `RequiredFields` is terminal-only and does not apply to either streaming
  mode (no schema struct to inspect).

  Both modes deliver a `:guardrail_violation` stream event with data
  `%{stage: :output, mode: :accumulate | :incremental, violations: violations}` and emit
  the `[:normandy, :agent, :guardrail, :violation]` telemetry event with metadata
  `streaming: true` and `mode: :accumulate | :incremental`.

  ## Telemetry

  A `[:normandy, :agent, :guardrail, :violation]` event is emitted per
  violation batch. One event per final-response emission, not per user turn —
  with `enable_json_retry` plus retries, a single turn can emit multiple
  output-guardrail events. Its `violations` are reduced to
  `%{guard:, path:, constraint:}` each: no message, so no forbidden term, pattern or
  model text (`SemanticScope`'s reason). The same holds for the `:decision` event below,
  a `ViolationError` in a run's `:exception` metadata and a `Turn.Server` turn state's
  persisted `error`. The full violations reach only the caller: the returned
  `ViolationError`, `admit/2,3`'s `{:block, violations}` and the stream event.

  `Normandy.Agents.BaseAgent.admit/2,3` additionally emits
  `[:normandy, :agent, :guardrail, :decision]` with `outcome` in
  `:admit | :block | :error`, so hosts can monitor admit/block/false-positive
  rates on one stream. The in-turn input path emits it too (it delegates to
  `admit/2`); it is suppressed when no guardrails are configured.
  """

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Guardrails.Guard
  alias Normandy.Guardrails.GuardError

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
                "expected #{inspect(mod)}.check/2 to return :ok or {:error, [violation]}, got: #{Describe.shape(other)}"
      end
    end)
  end

  # Invokes the guard under its `:on_error` policy. `:reraise` (default) lets a
  # crashing guard propagate — a config bug stays a crash, not a silent admit.
  # `:open` catches a raise, exit or throw and treats it as a pass; `:closed` turns
  # it into a `:guard_error` violation. Only the `check` call is caught: a
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
          # A built-in guard raises ArgumentError or KeyError only for its own
          # configuration (a :field typo, a bad or missing option): a bug to fix,
          # never a pass or a violation.
          exception in [ArgumentError, KeyError] ->
            if builtin?(mod),
              do: reraise(exception, __STACKTRACE__),
              else: on_error_result(policy, mod, exception)

          exception ->
            on_error_result(policy, mod, exception)
        catch
          :exit, reason -> on_error_result(policy, mod, {:exit, reason})
          :throw, value -> on_error_result(policy, mod, {:throw, value})
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

  defp builtin?(mod), do: String.starts_with?(inspect(mod), "Normandy.Guardrails.Builtins.")

  defp on_error_result(:open, _mod, _crash), do: :ok

  defp on_error_result(:closed, mod, crash) do
    {:error,
     [
       %{
         guard: mod,
         path: [],
         # The module or exit tag only: an exception's message can inspect the guarded
         # value, and this violation reaches the caller, telemetry and the store.
         message: "guard #{inspect(mod)} #{describe_crash(crash)}",
         constraint: :guard_error
       }
     ]}
  end

  defp describe_crash(%GuardError{} = error), do: "crashed: " <> Exception.message(error)
  defp describe_crash({:exit, reason}), do: "exited: " <> Describe.reason_tag(reason)
  defp describe_crash({:throw, _value}), do: "threw"
  defp describe_crash(exception), do: "crashed: " <> inspect(exception.__struct__)

  defp normalize(mod) when is_atom(mod), do: {mod, []}
  defp normalize({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}

  defp normalize(other) do
    raise ArgumentError,
          "invalid guard spec: expected module or {module, opts}, got: #{inspect(other)}"
  end
end
