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
  - `:on_error` — handled by `Normandy.Guardrails.run/2,3`, not here. A
    classifier that calls a flaky service should set `on_error: :open` so an
    outage admits rather than crashing the guard chain. See
    `Normandy.Guardrails` for the policy semantics (default `:reraise`).

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

  @impl true
  def check(value, opts), do: check(value, opts, %{})

  @impl true
  def check(value, opts, context) do
    classifier = Keyword.fetch!(opts, :classifier)
    fast_path = Keyword.get(opts, :fast_path, fn _value, _context -> :needs_classifier end)

    case fast_path.(value, context) do
      :admit ->
        :ok

      :needs_classifier ->
        classify(classifier, value, context)

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} :fast_path must return :admit or :needs_classifier, " <>
                "got: #{inspect(other)}"
    end
  end

  defp classify(classifier, value, context) do
    case classifier.(value, context) do
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
              "#{inspect(__MODULE__)} :classifier must return :allow or {:block, reason}, " <>
                "got: #{inspect(other)}"
    end
  end
end
