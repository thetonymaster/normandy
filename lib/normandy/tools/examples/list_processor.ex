defmodule Normandy.Tools.Examples.ListProcessor do
  @moduledoc """
  A tool for processing lists with various operations.

  ## Examples

      iex> tool = %Normandy.Tools.Examples.ListProcessor{operation: "sum", numbers: [1, 2, 3, 4, 5]}
      iex> Normandy.Tools.BaseTool.run(tool)
      {:ok, 15}

      iex> tool = %Normandy.Tools.Examples.ListProcessor{operation: "average", numbers: [10, 20, 30]}
      iex> Normandy.Tools.BaseTool.run(tool)
      {:ok, 20.0}

  """

  defstruct [:operation, :numbers]

  @type t :: %__MODULE__{
          operation: String.t(),
          numbers: [number()]
        }

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "list_processor"

    def tool_description(_) do
      "Performs operations on lists of numbers: sum, average, min, max, sort, count"
    end

    def input_schema(_) do
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

    def run(%{operation: "sum", numbers: numbers}) do
      {:ok, Enum.sum(numbers)}
    end

    def run(%{operation: "average", numbers: []}) do
      {:error, "Cannot calculate average of empty list"}
    end

    def run(%{operation: "average", numbers: numbers}) do
      {:ok, Enum.sum(numbers) / length(numbers)}
    end

    def run(%{operation: "min", numbers: []}) do
      {:error, "Cannot find minimum of empty list"}
    end

    def run(%{operation: "min", numbers: numbers}) do
      {:ok, Enum.min(numbers)}
    end

    def run(%{operation: "max", numbers: []}) do
      {:error, "Cannot find maximum of empty list"}
    end

    def run(%{operation: "max", numbers: numbers}) do
      {:ok, Enum.max(numbers)}
    end

    def run(%{operation: "sort_asc", numbers: numbers}) do
      {:ok, Enum.sort(numbers)}
    end

    def run(%{operation: "sort_desc", numbers: numbers}) do
      {:ok, Enum.sort(numbers, :desc)}
    end

    def run(%{operation: "count", numbers: numbers}) do
      {:ok, length(numbers)}
    end

    def run(%{operation: operation}) do
      {:error, "Unknown operation: #{operation}"}
    end
  end
end
