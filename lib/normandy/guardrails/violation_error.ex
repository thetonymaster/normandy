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
end
