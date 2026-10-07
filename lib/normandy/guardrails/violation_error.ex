defmodule Normandy.Guardrails.ViolationError do
  @moduledoc """
  Exception raised when an input guardrail rejects an agent's input.

  Modeled on `Normandy.Schema.ValidationError` so callers that already handle
  validation errors can rescue the two uniformly if desired.
  """

  defexception [:message, :violations]

  @type t :: %__MODULE__{
          message: String.t(),
          violations: [map()]
        }

  @impl true
  def exception(opts) do
    message = Keyword.get(opts, :message, "Guardrail violation")
    violations = Keyword.get(opts, :violations, [])

    %__MODULE__{
      message: message,
      violations: violations
    }
  end

  # The messages BaseAgent raises with; a redacted error keeps one of these, anything
  # else becomes the generic text.
  @normandy_messages ["Agent input guardrail violation", "Agent output guardrail violation"]

  @doc false
  # The form that leaves the caller's reply (telemetry, a persisted Turn.State.error):
  # the violations reduced to reduce_violations/1 and the message kept only when it is
  # one of Normandy's own fixed texts. A violation's message quotes the guard's
  # configuration (a forbidden term, a pattern) or model text (SemanticScope's reason).
  # Idempotent.
  @spec redact(t()) :: t()
  def redact(%__MODULE__{message: message, violations: violations} = error) do
    %{
      error
      | message: if(message in @normandy_messages, do: message, else: "Guardrail violation"),
        violations: reduce_violations(violations)
    }
  end

  @doc false
  # Each violation as `%{guard:, path:, constraint:}`: which guard, where and which rule,
  # never its message or any extra key a guard added.
  @spec reduce_violations(term()) :: [map()]
  def reduce_violations(violations) when is_list(violations),
    do: Enum.map(violations, &reduce_violation/1)

  def reduce_violations(_other), do: []

  defp reduce_violation(violation) when is_map(violation) do
    %{
      guard: Map.get(violation, :guard),
      path: Map.get(violation, :path, []),
      constraint: Map.get(violation, :constraint)
    }
  end

  defp reduce_violation(_other), do: %{guard: nil, path: [], constraint: nil}
end
