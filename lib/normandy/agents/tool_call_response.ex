defmodule Normandy.Agents.ToolCallResponse do
  @moduledoc """
  Response schema for agent outputs that may include tool calls.

  This schema allows the LLM to either provide a final text response
  or request tool executions.

  `:thinking` holds the response's `thinking` and `redacted_thinking` blocks
  in their wire shape (string keys, with `signature` or `data`). They are sent
  back unchanged, first, when the turn is replayed: a thinking model needs
  them on the assistant message that carries the tool calls.
  """

  use Normandy.Schema

  alias Normandy.Components.ToolCall

  @type t :: %__MODULE__{
          content: String.t() | nil,
          tool_calls: [ToolCall.t()],
          thinking: [map()]
        }

  schema do
    field(:content, :string, default: nil)
    field(:tool_calls, {:array, :struct}, default: [])
    field(:thinking, {:array, :map}, default: [])
  end

  @doc """
  The `thinking` and `redacted_thinking` blocks among response content blocks
  (atom or string keys), in order and in wire shape, for `:thinking`.
  """
  @spec thinking_blocks([map()]) :: [map()]
  def thinking_blocks(blocks) when is_list(blocks), do: Enum.flat_map(blocks, &thinking_block/1)

  defp thinking_block(block) do
    field = fn key -> Map.get(block, key) || Map.get(block, Atom.to_string(key)) end

    case field.(:type) do
      type when type in [:thinking, "thinking"] ->
        [
          %{
            "type" => "thinking",
            "thinking" => field.(:thinking),
            "signature" => field.(:signature)
          }
        ]

      type when type in [:redacted_thinking, "redacted_thinking"] ->
        [%{"type" => "redacted_thinking", "data" => field.(:data)}]

      _ ->
        []
    end
  end
end

defimpl Normandy.Components.BaseIOSchema, for: Normandy.Agents.ToolCallResponse do
  @moduledoc """
  BaseIOSchema protocol implementation for ToolCallResponse.

  Serializes ToolCallResponse to Claude API format with content blocks.
  """

  def to_json(%Normandy.Agents.ToolCallResponse{} = response) do
    # Thinking blocks come first, as the API returned them.
    response.thinking ++ content_blocks(response)
  end

  defp content_blocks(%{content: content, tool_calls: tool_calls}) do
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
          # The API requires an object. Input that was not one was refused
          # (Dispatch.classify/3), and the model was told in the tool result.
          input: if(is_map(tool_call.input), do: tool_call.input, else: %{})
        }

        [tool_block | acc]
      end)

    # Reverse to maintain correct order (text first, then tool_uses)
    blocks = Enum.reverse(blocks)

    blocks
  end

  def get_schema(_), do: %{}
  def __str__(_), do: "ToolCallResponse"
  def __rich__(_), do: "ToolCallResponse"
end
