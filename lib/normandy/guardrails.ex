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

  Output guardrails **do not** run on streaming paths: inspecting a
  partially-emitted response would require either buffering (defeating
  streaming) or post-hoc policy (the content has already reached the caller).
  If output-side content policy is load-bearing, use the non-streaming
  `BaseAgent.run/2`.

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
