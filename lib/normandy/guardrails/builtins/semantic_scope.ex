defmodule Normandy.Guardrails.Builtins.SemanticScope do
  @moduledoc """
  A hybrid scope guard: a cheap deterministic **fast path** in front of an
  injected **classifier**.

  Normandy owns only the orchestration shape. It is deliberately
  provider-agnostic — it knows nothing about LLMs, HTTP, prompts, locales, or
  block-lists. The host injects those as plain functions, so the same guard can
  front a keyword heuristic plus a remote inference call without any of that
  knowledge leaking into the framework.

  ## Options

  - `:classifier` (required) — `(value, context) -> :allow | {:block, reason}`.
    Called when the fast path defers. `reason` is an atom and becomes the
    violation's `:constraint`, so the host can map it to localized copy
    (e.g. `:off_topic`). Owns all IO.
  - `:fast_path` (optional) — `(value, context) -> :admit | :needs_classifier`.
    A cheap pre-filter. `:admit` short-circuits and the classifier never runs;
    `:needs_classifier` defers to the classifier. Defaults to always
    `:needs_classifier`.
  - `:on_error` — handled by `Normandy.Guardrails.run/2,3`. A
    classifier that calls a flaky service should set `on_error: :open` so an
    outage admits rather than crashing the guard chain. See
    `Normandy.Guardrails` for the policy semantics (default `:reraise`). Under
    `:open` or `:closed`, a raise, exit or throw inside `:classifier` or
    `:fast_path` (including a `KeyError` or `ArgumentError`, and a call timeout) is
    raised as a `Normandy.Guardrails.GuardError` and handled by that policy. Under
    `:reraise` it propagates unchanged. A missing `:classifier` or a return value
    of the wrong shape is a configuration error and raises whatever `:on_error` says.

  The functions are closures, so a `SemanticScope` guard cannot be stored in a
  `Turn.Session` template (`ConfigTemplate.from_config/2` refuses functions): use it
  with `BaseAgent.run/3`, `stream/3`, `admit/2,3`, or an inline `AgentProcess`.

  `context` (the third argument supplied by `Normandy.Guardrails.run/3` /
  `Normandy.Agents.BaseAgent.admit/3`) is passed unchanged to both injected
  functions. `check/2` runs them with an empty context.

  ## Example

      classifier = fn message, %{event_id: id} ->
        if MyApp.Inference.on_topic?(message, id), do: :allow, else: {:block, :off_topic}
      end

      fast_path = fn message, _context ->
        if MyApp.Keywords.obviously_in_scope?(message), do: :admit, else: :needs_classifier
      end

      guards = [{SemanticScope, classifier: classifier, fast_path: fast_path, on_error: :open}]
      Normandy.Agents.BaseAgent.admit(config, message, %{event_id: 42})
  """

  @behaviour Normandy.Guardrails.Guard

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Guardrails.Builtins.Field
  alias Normandy.Guardrails.GuardError

  @impl true
  def check(value, opts), do: check(value, opts, %{})

  @impl true
  def check(value, opts, context) do
    classifier = Keyword.fetch!(opts, :classifier)
    # A default-schema input is classified as its chat_message text.
    value = Field.extract!(__MODULE__, value, nil)
    fast_path = Keyword.get(opts, :fast_path, fn _value, _context -> :needs_classifier end)

    case call_host(fast_path, value, context, opts) do
      :admit ->
        :ok

      :needs_classifier ->
        classify(classifier, value, context, opts)

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} :fast_path must return :admit or :needs_classifier, " <>
                "got: " <> Describe.type_of(other)
    end
  end

  defp classify(classifier, value, context, opts) do
    case call_host(classifier, value, context, opts) do
      :allow ->
        :ok

      {:block, reason} when is_atom(reason) ->
        {:error,
         [
           %{
             guard: __MODULE__,
             path: [],
             message: "blocked by semantic scope: #{reason}",
             constraint: reason
           }
         ]}

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} :classifier must return :allow or {:block, reason} " <>
                "(reason an atom), got: " <> Describe.type_of(other)
    end
  end

  # Host code is not this guard's configuration: under :open or :closed its crash is a
  # GuardError, which Guardrails.run/3 hands to the policy (a builtin's own ArgumentError
  # or KeyError always raises). Under :reraise it propagates as it is, stacktrace and all.
  defp call_host(fun, value, context, opts) do
    if Keyword.get(opts, :on_error, :reraise) == :reraise do
      fun.(value, context)
    else
      try do
        fun.(value, context)
      rescue
        exception ->
          reraise GuardError, [kind: :error, reason: exception], __STACKTRACE__
      catch
        kind, reason when kind in [:exit, :throw] ->
          reraise GuardError, [kind: kind, reason: reason], __STACKTRACE__
      end
    end
  end
end
