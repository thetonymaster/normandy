defmodule Normandy.Components.PromptSpecification do
  @moduledoc """
  Defines the structure of an agent's system prompt.

  Organizes prompts into sections: background (identity), steps (internal process),
  output instructions, and dynamic context providers.
  """

  use Normandy.Schema

  @type t :: %__MODULE__{
          background: [String.t()],
          steps: [String.t()],
          output_instructions: [String.t()],
          context_providers: %{atom() => struct()}
        }

  schema do
    field(:background, {:array, :string}, default: [])
    field(:steps, {:array, :string}, default: [])
    field(:output_instructions, {:array, :string}, default: [])
    field(:context_providers, {:map, :any}, default: %{})
  end
end
