defmodule NormandyTest.Tools.BaseToolTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.BaseTool

  defmodule TestTool do
    defstruct [:config]

    defimpl Normandy.Tools.BaseTool do
      def tool_name(_), do: "test_tool"
      def tool_description(_), do: "A test tool for unit testing"

      def input_schema(_) do
        %{
          type: "object",
          properties: %{
            config: %{type: "string", description: "Configuration string"}
          },
          required: ["config"]
        }
      end

      def run(%{config: config}), do: {:ok, "Result: #{config}"}
    end
  end

  defmodule CalculatorTool do
    defstruct [:operation, :a, :b]

    defimpl Normandy.Tools.BaseTool do
      def tool_name(_), do: "calculator"
      def tool_description(_), do: "Performs basic arithmetic operations"

      def input_schema(_) do
        %{
          type: "object",
          properties: %{
            operation: %{
              type: "string",
              enum: ["add", "subtract", "multiply", "divide"],
              description: "The arithmetic operation to perform"
            },
            a: %{type: "number", description: "First operand"},
            b: %{type: "number", description: "Second operand"}
          },
          required: ["operation", "a", "b"]
        }
      end

      def run(%{operation: :add, a: a, b: b}), do: {:ok, a + b}
      def run(%{operation: :subtract, a: a, b: b}), do: {:ok, a - b}
      def run(%{operation: :multiply, a: a, b: b}), do: {:ok, a * b}
      def run(%{operation: :divide, a: _a, b: 0}), do: {:error, "Division by zero"}
      def run(%{operation: :divide, a: a, b: b}), do: {:ok, a / b}
      def run(_), do: {:error, "Unknown operation"}
    end
  end

  describe "BaseTool protocol" do
    test "returns tool name" do
      tool = %TestTool{config: "test"}
      assert BaseTool.tool_name(tool) == "test_tool"
    end

    test "returns tool description" do
      tool = %TestTool{config: "test"}
      assert BaseTool.tool_description(tool) == "A test tool for unit testing"
    end

    test "runs tool and returns result" do
      tool = %TestTool{config: "hello"}
      assert BaseTool.run(tool) == {:ok, "Result: hello"}
    end
  end

  describe "CalculatorTool implementation" do
    test "addition" do
      tool = %CalculatorTool{operation: :add, a: 5, b: 3}
      assert BaseTool.run(tool) == {:ok, 8}
    end

    test "subtraction" do
      tool = %CalculatorTool{operation: :subtract, a: 10, b: 4}
      assert BaseTool.run(tool) == {:ok, 6}
    end

    test "multiplication" do
      tool = %CalculatorTool{operation: :multiply, a: 7, b: 6}
      assert BaseTool.run(tool) == {:ok, 42}
    end

    test "division" do
      tool = %CalculatorTool{operation: :divide, a: 20, b: 4}
      assert BaseTool.run(tool) == {:ok, 5.0}
    end

    test "division by zero returns error" do
      tool = %CalculatorTool{operation: :divide, a: 10, b: 0}
      assert BaseTool.run(tool) == {:error, "Division by zero"}
    end

    test "unknown operation returns error" do
      tool = %CalculatorTool{operation: :power, a: 2, b: 3}
      assert BaseTool.run(tool) == {:error, "Unknown operation"}
    end

    test "tool name for calculator" do
      tool = %CalculatorTool{operation: :add, a: 1, b: 1}
      assert BaseTool.tool_name(tool) == "calculator"
    end

    test "tool description for calculator" do
      tool = %CalculatorTool{operation: :add, a: 1, b: 1}
      assert BaseTool.tool_description(tool) == "Performs basic arithmetic operations"
    end
  end
end
