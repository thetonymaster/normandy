defmodule Normandy.Tools.Examples.Calculator do
  @moduledoc """
  A calculator tool for performing basic arithmetic operations.

  Now uses Normandy's schema-based tool definition for automatic validation
  and reduced boilerplate code.

  ## Examples

      iex> {:ok, calculator} = Calculator.validate(%{operation: "add", a: 5, b: 3})
      iex> Normandy.Tools.BaseTool.run(calculator)
      {:ok, 8}

      iex> {:ok, calculator} = Calculator.validate(%{operation: "divide", a: 10, b: 0})
      iex> Normandy.Tools.BaseTool.run(calculator)
      {:error, "Cannot divide by zero"}

  ## Schema-Based Benefits

  - Automatic JSON schema generation
  - Runtime validation before execution
  - Reduced code (~60% less than manual approach)
  - Better error messages with field paths
  - Type coercion and constraint checking

  """

  use Normandy.Tools.SchemaBaseTool

  tool_schema "calculator",
              "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers" do
    field(:operation, :string,
      required: true,
      enum: ["add", "subtract", "multiply", "divide"],
      description: "The arithmetic operation to perform"
    )

    field(:a, :float,
      required: true,
      description: "The first number (operand)"
    )

    field(:b, :float,
      required: true,
      description: "The second number (operand)"
    )
  end

  # Implementation of the execute/1 callback
  def execute(%__MODULE__{operation: "add", a: a, b: b}) do
    result = to_float(a) + to_float(b)
    {:ok, result}
  end

  def execute(%__MODULE__{operation: "subtract", a: a, b: b}) do
    result = to_float(a) - to_float(b)
    {:ok, result}
  end

  def execute(%__MODULE__{operation: "multiply", a: a, b: b}) do
    result = to_float(a) * to_float(b)
    {:ok, result}
  end

  def execute(%__MODULE__{operation: "divide", a: _a, b: b}) when b == 0 or b == 0.0 do
    {:error, "Cannot divide by zero"}
  end

  def execute(%__MODULE__{operation: "divide", a: a, b: b}) do
    result = to_float(a) / to_float(b)
    {:ok, result}
  end

  def execute(%__MODULE__{operation: operation}) do
    {:error, "Unknown operation: #{operation}"}
  end

  # Helper to ensure values are floats for arithmetic operations
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
end
