defmodule Normandy.Tools.Examples.Calculator do
  @moduledoc """
  A test tool: adds, subtracts, multiplies or divides two numbers. Its input is
  `Normandy.Tools.Examples.Calculator.Input` (types are checked, not coerced: `a: "5"` is
  rejected before `run/2`).
  """

  defmodule Input do
    @moduledoc false
    use Normandy.Schema

    io_schema "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers" do
      field(:operation, :string,
        required: true,
        enum: ["add", "subtract", "multiply", "divide"],
        description: "The arithmetic operation to perform"
      )

      field(:a, :float, required: true, description: "The first number (operand)")
      field(:b, :float, required: true, description: "The second number (operand)")
    end
  end

  use Normandy.Tool,
    name: "calculator",
    description:
      "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers",
    input: Input

  alias Normandy.Tools.Context

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Context{input: %Input{} = input}), do: calculate(input)

  defp calculate(%Input{operation: "add", a: a, b: b}), do: {:ok, to_float(a) + to_float(b)}
  defp calculate(%Input{operation: "subtract", a: a, b: b}), do: {:ok, to_float(a) - to_float(b)}
  defp calculate(%Input{operation: "multiply", a: a, b: b}), do: {:ok, to_float(a) * to_float(b)}

  defp calculate(%Input{operation: "divide", b: b}) when b == 0 or b == 0.0,
    do: {:error, "Cannot divide by zero"}

  defp calculate(%Input{operation: "divide", a: a, b: b}), do: {:ok, to_float(a) / to_float(b)}
  defp calculate(%Input{operation: operation}), do: {:error, "Unknown operation: #{operation}"}

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
end
