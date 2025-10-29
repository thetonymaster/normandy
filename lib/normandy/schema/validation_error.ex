defmodule Normandy.Schema.ValidationError do
  @moduledoc """
  Exception raised when schema validation fails.
  """

  defexception [:message, :errors]

  @type t :: %__MODULE__{
          message: String.t(),
          errors: [map()]
        }

  @impl true
  def exception(opts) do
    message = Keyword.get(opts, :message, "Validation failed")
    errors = Keyword.get(opts, :errors, [])

    %__MODULE__{
      message: message,
      errors: errors
    }
  end
end
