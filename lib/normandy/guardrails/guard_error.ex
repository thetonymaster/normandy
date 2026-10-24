defmodule Normandy.Guardrails.GuardError do
  @moduledoc """
  Raised by a guard when host code it calls fails: the `:classifier` or `:fast_path`
  function of `Normandy.Guardrails.Builtins.SemanticScope`, or the same in a guard of your
  own. `Normandy.Guardrails.run/3` handles it under the guard's `:on_error` like any other
  crash, so a guard's own configuration errors (an `ArgumentError` or `KeyError` from a
  built-in guard) stay apart from failures of the code the host injected.

    * `kind` - `:error` (a raise), `:exit` or `:throw`.
    * `reason` - the exception, exit reason or thrown value. It is never shown: the
      message names the exception's module or the exit's tag only.
  """

  alias Normandy.Components.ContentBlock.Describe

  defexception [:kind, :reason]

  @type t :: %__MODULE__{kind: :error | :exit | :throw, reason: term()}

  @impl true
  def message(%__MODULE__{kind: :error, reason: reason}),
    do: "host code raised " <> Describe.reason_tag(reason)

  def message(%__MODULE__{kind: :exit, reason: reason}),
    do: "host code exited: " <> Describe.reason_tag(reason)

  def message(%__MODULE__{kind: :throw}), do: "host code threw"
end
