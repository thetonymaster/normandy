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
        content: format_tool_output(result.output),
        is_error: result.is_error
      }
    ]

    blocks
  end

  defp format_tool_output(output) when is_binary(output), do: output
  defp format_tool_output(output) when is_number(output), do: to_string(output)

  # Anything else (a map, a list, an atom, a boolean, nil) goes to the model as
  # JSON. Dispatch turns an output JSON cannot express into an error result after
  # every hook has run, so this raises only for a ToolResult built outside Dispatch.
  defp format_tool_output(output), do: Normandy.JSON.encode!(output)

  def get_schema(_), do: %{}
end
