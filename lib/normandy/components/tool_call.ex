defmodule Normandy.Components.ToolCall do
  @moduledoc """
  Represents a tool call request from the LLM.

  Tool calls contain the name of the tool to execute and the input parameters.
  """

  use Normandy.Schema

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map()
        }

  schema do
    field(:id, :string)
    field(:name, :string)
    field(:input, :map)
  end
end
