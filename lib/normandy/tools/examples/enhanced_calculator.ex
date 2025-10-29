defmodule Normandy.Tools.Examples.EnhancedCalculator do
  @moduledoc """
  Schema-based calculator tool demonstrating the new SchemaBaseTool approach.

  This is an enhanced version of the Calculator tool that uses Normandy schemas
  for input definition, providing automatic validation and better error messages.

  ## Comparison with Original Calculator

  **Original Approach** (manual schema definition):
  - Manually define struct fields
  - Manually write JSON schema in `input_schema/1`
  - No automatic validation
  - Duplication between struct and schema

  **Schema-Based Approach** (this module):
  - Define schema once with `tool_schema`
  - Automatic JSON schema generation
  - Built-in validation with detailed errors
  - Type coercion and default values
  - Format validation support

  ## Examples

      # Create and validate
      iex> {:ok, calc} = EnhancedCalculator.validate(%{operation: "add", a: 5, b: 3})
      iex> EnhancedCalculator.execute(calc)
      {:ok, 8}

      # Validation catches errors
      iex> EnhancedCalculator.validate(%{operation: "invalid", a: 5, b: 3})
      {:error, [%{path: [:operation], constraint: :enum, ...}]}

      # Automatic through BaseTool protocol
      iex> tool = %EnhancedCalculator{operation: "multiply", a: 4, b: 7}
      iex> Normandy.Tools.BaseTool.run(tool)
      {:ok, 28}
  """

  use Normandy.Tools.SchemaBaseTool

  tool_schema "enhanced_calculator",
              "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers with validation" do
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

    field(:precision, :integer,
      description: "Number of decimal places in result",
      default: 2,
      minimum: 0,
      maximum: 10
    )
  end

  # Implementation of the execute/1 callback required by SchemaBaseTool
  def execute(%__MODULE__{operation: "add", a: a, b: b, precision: precision}) do
    result = to_float(a) + to_float(b)
    {:ok, Float.round(result, precision)}
  end

  def execute(%__MODULE__{operation: "subtract", a: a, b: b, precision: precision}) do
    result = to_float(a) - to_float(b)
    {:ok, Float.round(result, precision)}
  end

  def execute(%__MODULE__{operation: "multiply", a: a, b: b, precision: precision}) do
    result = to_float(a) * to_float(b)
    {:ok, Float.round(result, precision)}
  end

  def execute(%__MODULE__{operation: "divide", a: _a, b: b, precision: _precision})
      when b == 0 or b == 0.0 do
    {:error, "Cannot divide by zero"}
  end

  def execute(%__MODULE__{operation: "divide", a: a, b: b, precision: precision}) do
    result = to_float(a) / to_float(b)
    {:ok, Float.round(result, precision)}
  end

  # Helper to ensure values are floats for Float.round/2
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
end
