defmodule Normandy.Tools.Examples.Calculator do
  @moduledoc """
  A calculator tool for performing basic arithmetic operations.

  ## Examples

      iex> calculator = %Normandy.Tools.Examples.Calculator{operation: "add", a: 5, b: 3}
      iex> Normandy.Tools.BaseTool.run(calculator)
      {:ok, 8}

      iex> calculator = %Normandy.Tools.Examples.Calculator{operation: "divide", a: 10, b: 0}
      iex> Normandy.Tools.BaseTool.run(calculator)
      {:error, "Cannot divide by zero"}

  """

  defstruct [:operation, :a, :b]

  @type t :: %__MODULE__{
          operation: String.t(),
          a: number(),
          b: number()
        }

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "calculator"

    def tool_description(_) do
      "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers"
    end

    def input_schema(_) do
      %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["add", "subtract", "multiply", "divide"],
            description: "The arithmetic operation to perform"
          },
          a: %{
            type: "number",
            description: "The first number (operand)"
          },
          b: %{
            type: "number",
            description: "The second number (operand)"
          }
        },
        required: ["operation", "a", "b"]
      }
    end

    def run(%{operation: "add", a: a, b: b}) do
      {:ok, a + b}
    end

    def run(%{operation: "subtract", a: a, b: b}) do
      {:ok, a - b}
    end

    def run(%{operation: "multiply", a: a, b: b}) do
      {:ok, a * b}
    end

    def run(%{operation: "divide", a: _a, b: 0}) do
      {:error, "Cannot divide by zero"}
    end

    def run(%{operation: "divide", a: a, b: b}) do
      {:ok, a / b}
    end

    def run(%{operation: operation}) do
      {:error,
       "Unknown operation: #{operation}. Supported operations: add, subtract, multiply, divide"}
    end
  end
end
