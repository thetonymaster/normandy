defmodule Normandy.Tools.Examples.EnhancedCalculator do
  @moduledoc """
  A test tool: `Normandy.Tools.Examples.Calculator` with a `precision` input (decimal places
  of the result, default 2, 0 to 10).
  """

  defmodule Input do
    @moduledoc false
    use Normandy.Schema

    io_schema "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers with validation" do
      field(:operation, :string,
        required: true,
        enum: ["add", "subtract", "multiply", "divide"],
        description: "The arithmetic operation to perform"
      )

      field(:a, :float, required: true, description: "The first number (operand)")
      field(:b, :float, required: true, description: "The second number (operand)")

      field(:precision, :integer,
        description: "Number of decimal places in result",
        default: 2,
        minimum: 0,
        maximum: 10
      )
    end
  end

  use Normandy.Tool,
    name: "enhanced_calculator",
    description:
      "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers with validation",
    input: Input

  alias Normandy.Tools.Context

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Context{input: %Input{} = input}), do: calculate(input)

  defp calculate(%Input{operation: "divide", b: b}) when b == 0 or b == 0.0,
    do: {:error, "Cannot divide by zero"}

  defp calculate(%Input{operation: operation, a: a, b: b, precision: precision}) do
    result =
      case operation do
        "add" -> to_float(a) + to_float(b)
        "subtract" -> to_float(a) - to_float(b)
        "multiply" -> to_float(a) * to_float(b)
        "divide" -> to_float(a) / to_float(b)
      end

    {:ok, Float.round(result, precision)}
  end

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
end
