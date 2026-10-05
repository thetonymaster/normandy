defmodule Normandy.Tools.Examples.ListProcessor do
  @moduledoc """
  A test tool with a hand-written input schema: sum, average, min, max, sort or count a list
  of numbers. `run/2` gets the validated input as a string-keyed map.
  """
  use Normandy.Tool,
    name: "list_processor",
    description: "Performs operations on lists of numbers: sum, average, min, max, sort, count"

  alias Normandy.Tools.Context

  defstruct []

  @impl Normandy.Tool
  def input_schema(_tool) do
    %{
      type: "object",
      properties: %{
        operation: %{
          type: "string",
          enum: ["sum", "average", "min", "max", "sort_asc", "sort_desc", "count"],
          description: "The list operation to perform"
        },
        numbers: %{
          type: "array",
          items: %{type: "number"},
          description: "The list of numbers to process"
        }
      },
      required: ["operation", "numbers"]
    }
  end

  @impl Normandy.Tool
  def run(_tool, %Context{input: %{"operation" => operation, "numbers" => numbers}}),
    do: process(operation, numbers)

  defp process("sum", numbers), do: {:ok, Enum.sum(numbers)}
  defp process("average", []), do: {:error, "Cannot calculate average of empty list"}
  defp process("average", numbers), do: {:ok, Enum.sum(numbers) / length(numbers)}
  defp process("min", []), do: {:error, "Cannot find minimum of empty list"}
  defp process("min", numbers), do: {:ok, Enum.min(numbers)}
  defp process("max", []), do: {:error, "Cannot find maximum of empty list"}
  defp process("max", numbers), do: {:ok, Enum.max(numbers)}
  defp process("sort_asc", numbers), do: {:ok, Enum.sort(numbers)}
  defp process("sort_desc", numbers), do: {:ok, Enum.sort(numbers, :desc)}
  defp process("count", numbers), do: {:ok, length(numbers)}
  defp process(operation, _numbers), do: {:error, "Unknown operation: #{operation}"}
end
