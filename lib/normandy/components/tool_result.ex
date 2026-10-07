defmodule Normandy.Components.ToolResult do
  @moduledoc """
  Represents the result of executing a tool.

  Contains the tool call ID, whether it succeeded, and the result or error.
  """

  use Normandy.Schema

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          output: term(),
          is_error: boolean()
        }

  schema do
    field(:tool_call_id, :string)
    # Any term the tool returned: text, a number, a map or a list.
    field(:output, :any)
    field(:is_error, :boolean, default: false)
  end

  @doc false
  # The text the model reads for `output` (BaseIOSchema.to_json/1 below, and the cap in
  # Normandy.Agents.Dispatch.finish/3): a binary as-is, a number as its digits, anything
  # else (a map, a list, an atom, a boolean, nil) as JSON, every plain map's keys sorted
  # (Normandy.JSON "Text for the model": the same result is the same text on every node).
  # Dispatch turns an output JSON cannot express into an error result after every hook
  # has run, so this raises only for a ToolResult built outside Dispatch.
  @spec render_output(term()) :: String.t()
  def render_output(output) when is_binary(output), do: output
  def render_output(output) when is_number(output), do: to_string(output)
  def render_output(output), do: output |> Normandy.JSON.sort_keys() |> Normandy.JSON.encode!()
end

defimpl Normandy.Components.BaseIOSchema, for: Normandy.Components.ToolResult do
  @moduledoc """
  BaseIOSchema protocol implementation for ToolResult.

  Serializes ToolResult to Claude API format with tool_result content blocks.
  """

  def to_json(%Normandy.Components.ToolResult{} = result) do
    # Format tool result as Claude API content block
    blocks = [
      %{
        type: "tool_result",
        tool_use_id: result.tool_call_id,
        content: Normandy.Components.ToolResult.render_output(result.output),
        is_error: result.is_error
      }
    ]

    blocks
  end

  def get_schema(_), do: %{}
end
