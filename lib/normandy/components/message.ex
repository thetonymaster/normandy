defmodule Normandy.Components.Message do
  @moduledoc """
  Represents a single message in agent conversation history.
  """

  use Normandy.Schema

  @type t :: %__MODULE__{
          role: String.t(),
          content: struct(),
          turn_id: String.t()
        }

  schema do
    field(:role, :string)
    field(:content, :struct)
    field(:turn_id, :string)
  end
end
