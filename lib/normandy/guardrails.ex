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
  """

  alias Normandy.Guardrails.Guard

  @type spec :: module() | {module(), keyword()}

  @doc """
  Runs the guard list against `value`.

  Returns `{:ok, value}` if every guard passes, or `{:error, [violation]}` as
  soon as one fails. An empty guard list is always `{:ok, value}`.
  """
  @spec run([spec()], term()) :: {:ok, term()} | {:error, [Guard.violation()]}
  def run([], value), do: {:ok, value}

  def run(guards, value) when is_list(guards) do
    Enum.reduce_while(guards, {:ok, value}, fn spec, {:ok, v} ->
      {mod, opts} = normalize(spec)

      case mod.check(v, opts) do
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

  defp normalize(mod) when is_atom(mod), do: {mod, []}
  defp normalize({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}

  defp normalize(other) do
    raise ArgumentError,
          "invalid guard spec: expected module or {module, opts}, got: #{inspect(other)}"
  end
end
