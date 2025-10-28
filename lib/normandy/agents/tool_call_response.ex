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

defimpl Normandy.Components.BaseIOSchema, for: Normandy.Agents.ToolCallResponse do
  @moduledoc """
  BaseIOSchema protocol implementation for ToolCallResponse.

  Serializes ToolCallResponse to Claude API format with content blocks.
  """

  def to_json(%Normandy.Agents.ToolCallResponse{content: content, tool_calls: tool_calls}) do
    # Build content blocks array for Claude API
    blocks = []

    # Add text content block if present
    blocks =
      if content && content != "" do
        [%{type: "text", text: content} | blocks]
      else
        blocks
      end

    # Add tool_use blocks
    blocks =
      Enum.reduce(tool_calls, blocks, fn tool_call, acc ->
        tool_block = %{
          type: "tool_use",
          id: tool_call.id,
          name: tool_call.name,
          input: tool_call.input
        }

        [tool_block | acc]
      end)

    # Reverse to maintain correct order (text first, then tool_uses)
    blocks = Enum.reverse(blocks)

    # Encode to JSON string
    adapter = Application.get_env(:normandy, :adapter, Poison)
    adapter.encode!(blocks)
  end

  def get_schema(_), do: %{}
  def __str__(_), do: "ToolCallResponse"
  def __rich__(_), do: "ToolCallResponse"
end
