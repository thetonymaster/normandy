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
  # The text the model reads for `output` (BaseIOSchema.to_json/1 below, and
  # Normandy.Agents.Dispatch, which renders each output once for its encodability check
  # and its cap): a binary as-is, a number as its digits, anything else (a map, a list,
  # an atom, a boolean, nil) as JSON, every plain map's keys sorted (Normandy.JSON "Text
  # for the model": the same result is the same text on every node). An output JSON
  # cannot express is {:error, exception}: what sorting its keys raised (a tuple key, an
  # improper list) or what the adapter raised (Normandy.JSON.encode/2; a misconfigured
  # :adapter still raises). A binary is returned unchecked; Dispatch checks its UTF-8.
  @spec render(term()) :: {:ok, String.t()} | {:error, Exception.t()}
  def render(output) when is_binary(output), do: {:ok, output}
  def render(output) when is_number(output), do: {:ok, to_string(output)}

  def render(output) do
    with {:ok, sorted} <- sort_keys(output), do: Normandy.JSON.encode(sorted)
  end

  defp sort_keys(output) do
    {:ok, Normandy.JSON.sort_keys(output)}
  rescue
    exception -> {:error, exception}
  end

  @doc false
  # render/1's text. Dispatch turns an output JSON cannot express into an error result
  # after every hook has run, so this raises only for a ToolResult built outside Dispatch.
  @spec render_output(term()) :: String.t()
  def render_output(output) do
    case render(output) do
      {:ok, text} -> text
      {:error, exception} -> raise exception
    end
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
        content: Normandy.Components.ToolResult.render_output(result.output),
        is_error: result.is_error
      }
    ]

    blocks
  end

  def get_schema(_), do: %{}
end
