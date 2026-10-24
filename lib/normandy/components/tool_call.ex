defmodule Normandy.Components.ToolCall do
  @moduledoc """
  Represents a tool call request from the LLM.

  Tool calls contain the name of the tool to execute and the input parameters.
  """

  use Normandy.Schema

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          # A map, or the raw input when the model sent something that is not a
          # JSON object (refused by Dispatch.classify/3).
          input: map() | term()
        }

  schema do
    field(:id, :string)
    field(:name, :string)
    field(:input, :map)
  end
end
