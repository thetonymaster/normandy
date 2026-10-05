defmodule Normandy.Tools.Examples.StringManipulator do
  @moduledoc """
  A test tool with a hand-written input schema: uppercase, lowercase, reverse, split,
  truncate or measure a string. `run/2` gets the validated input as a string-keyed map.
  """
  use Normandy.Tool,
    name: "string_manipulator",
    description:
      "Performs various string manipulation operations like uppercase, lowercase, reverse, split, truncate, etc."

  alias Normandy.Tools.Context

  defstruct []

  @impl Normandy.Tool
  def input_schema(_tool) do
    %{
      type: "object",
      properties: %{
        operation: %{
          type: "string",
          enum: ["uppercase", "lowercase", "reverse", "split", "truncate", "length"],
          description: "The string operation to perform"
        },
        text: %{type: "string", description: "The input text to manipulate"},
        delimiter: %{type: "string", description: "Delimiter for split operation (optional)"},
        count: %{
          type: "integer",
          description: "Number of characters for truncate operation (optional)"
        }
      },
      required: ["operation", "text"]
    }
  end

  @impl Normandy.Tool
  def run(_tool, %Context{input: %{"operation" => operation, "text" => text} = input}),
    do: process(operation, text, input)

  defp process("uppercase", text, _input), do: {:ok, String.upcase(text)}
  defp process("lowercase", text, _input), do: {:ok, String.downcase(text)}
  defp process("reverse", text, _input), do: {:ok, String.reverse(text)}

  defp process("split", text, %{"delimiter" => delimiter}),
    do: {:ok, String.split(text, delimiter)}

  defp process("split", text, _input), do: {:ok, String.split(text)}
  defp process("truncate", text, %{"count" => count}), do: {:ok, String.slice(text, 0, count)}

  defp process("truncate", _text, _input),
    do: {:error, "truncate operation requires 'count' parameter"}

  defp process("length", text, _input), do: {:ok, String.length(text)}
  defp process(operation, _text, _input), do: {:error, "Unknown operation: #{operation}"}
end
