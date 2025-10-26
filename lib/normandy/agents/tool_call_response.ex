defmodule Normandy.Agents.ToolCallResponse do
  @moduledoc """
  Response schema for agent outputs that may include tool calls.

  This schema allows the LLM to either provide a final text response
  or request tool executions.
  """

  use Normandy.Schema

  alias Normandy.Components.ToolCall

  @type t :: %__MODULE__{
          content: String.t() | nil,
          tool_calls: [ToolCall.t()]
        }

  schema do
    field(:content, :string, default: nil)
    field(:tool_calls, {:array, :struct}, default: [])
  end
end
