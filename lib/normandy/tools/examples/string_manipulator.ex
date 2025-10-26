defmodule Normandy.Tools.Examples.StringManipulator do
  @moduledoc """
  A tool for performing string manipulation operations.

  ## Examples

      iex> tool = %Normandy.Tools.Examples.StringManipulator{operation: "uppercase", text: "hello"}
      iex> Normandy.Tools.BaseTool.run(tool)
      {:ok, "HELLO"}

      iex> tool = %Normandy.Tools.Examples.StringManipulator{operation: "reverse", text: "hello"}
      iex> Normandy.Tools.BaseTool.run(tool)
      {:ok, "olleh"}

  """

  defstruct [:operation, :text, :delimiter, :count]

  @type t :: %__MODULE__{
          operation: String.t(),
          text: String.t(),
          delimiter: String.t() | nil,
          count: integer() | nil
        }

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "string_manipulator"

    def tool_description(_) do
      "Performs various string manipulation operations like uppercase, lowercase, reverse, split, truncate, etc."
    end

    def input_schema(_) do
      %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["uppercase", "lowercase", "reverse", "split", "truncate", "length"],
            description: "The string operation to perform"
          },
          text: %{
            type: "string",
            description: "The input text to manipulate"
          },
          delimiter: %{
            type: "string",
            description: "Delimiter for split operation (optional)"
          },
          count: %{
            type: "integer",
            description: "Number of characters for truncate operation (optional)"
          }
        },
        required: ["operation", "text"]
      }
    end

    def run(%{operation: "uppercase", text: text}) do
      {:ok, String.upcase(text)}
    end

    def run(%{operation: "lowercase", text: text}) do
      {:ok, String.downcase(text)}
    end

    def run(%{operation: "reverse", text: text}) do
      {:ok, String.reverse(text)}
    end

    def run(%{operation: "split", text: text, delimiter: delimiter}) when not is_nil(delimiter) do
      {:ok, String.split(text, delimiter)}
    end

    def run(%{operation: "split", text: text}) do
      {:ok, String.split(text)}
    end

    def run(%{operation: "truncate", text: text, count: count}) when not is_nil(count) do
      {:ok, String.slice(text, 0, count)}
    end

    def run(%{operation: "truncate", text: _text}) do
      {:error, "truncate operation requires 'count' parameter"}
    end

    def run(%{operation: "length", text: text}) do
      {:ok, String.length(text)}
    end

    def run(%{operation: operation}) do
      {:error, "Unknown operation: #{operation}"}
    end
  end
end
