defmodule NormandyTest.Tools.ExamplesTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.BaseTool
  alias Normandy.Tools.Examples.{Calculator, StringManipulator, ListProcessor}

  describe "Calculator tool" do
    test "performs addition" do
      tool = %Calculator{operation: "add", a: 10, b: 5}
      assert {:ok, 15.0} = BaseTool.run(tool)
    end

    test "performs subtraction" do
      tool = %Calculator{operation: "subtract", a: 10, b: 3}
      assert {:ok, 7.0} = BaseTool.run(tool)
    end

    test "performs multiplication" do
      tool = %Calculator{operation: "multiply", a: 6, b: 7}
      assert {:ok, 42.0} = BaseTool.run(tool)
    end

    test "performs division" do
      tool = %Calculator{operation: "divide", a: 20, b: 4}
      assert {:ok, 5.0} = BaseTool.run(tool)
    end

    test "handles division by zero" do
      tool = %Calculator{operation: "divide", a: 10, b: 0}
      assert {:error, "Cannot divide by zero"} = BaseTool.run(tool)
    end

    test "handles unknown operation" do
      tool = %Calculator{operation: "power", a: 2, b: 3}
      assert {:error, error} = BaseTool.run(tool)
      assert error =~ "Unknown operation"
    end

    test "provides correct metadata" do
      tool = %Calculator{operation: "add", a: 1, b: 1}
      assert BaseTool.tool_name(tool) == "calculator"
      assert BaseTool.tool_description(tool) =~ "arithmetic"

      schema = BaseTool.input_schema(tool)
      assert schema.type == :object
      assert Map.has_key?(schema.properties, :operation)
    end
  end

  describe "StringManipulator tool" do
    test "converts to uppercase" do
      tool = %StringManipulator{operation: "uppercase", text: "hello world"}
      assert {:ok, "HELLO WORLD"} = BaseTool.run(tool)
    end

    test "converts to lowercase" do
      tool = %StringManipulator{operation: "lowercase", text: "HELLO WORLD"}
      assert {:ok, "hello world"} = BaseTool.run(tool)
    end

    test "reverses string" do
      tool = %StringManipulator{operation: "reverse", text: "hello"}
      assert {:ok, "olleh"} = BaseTool.run(tool)
    end

    test "splits string with delimiter" do
      tool = %StringManipulator{operation: "split", text: "a,b,c", delimiter: ","}
      assert {:ok, ["a", "b", "c"]} = BaseTool.run(tool)
    end

    test "splits string without delimiter (whitespace)" do
      tool = %StringManipulator{operation: "split", text: "hello world test"}
      assert {:ok, ["hello", "world", "test"]} = BaseTool.run(tool)
    end

    test "truncates string" do
      tool = %StringManipulator{operation: "truncate", text: "hello world", count: 5}
      assert {:ok, "hello"} = BaseTool.run(tool)
    end

    test "requires count for truncate" do
      tool = %StringManipulator{operation: "truncate", text: "hello"}
      assert {:error, error} = BaseTool.run(tool)
      assert error =~ "count"
    end

    test "returns string length" do
      tool = %StringManipulator{operation: "length", text: "hello"}
      assert {:ok, 5} = BaseTool.run(tool)
    end

    test "handles unknown operation" do
      tool = %StringManipulator{operation: "invalid", text: "test"}
      assert {:error, error} = BaseTool.run(tool)
      assert error =~ "Unknown operation"
    end
  end

  describe "ListProcessor tool" do
    test "calculates sum" do
      tool = %ListProcessor{operation: "sum", numbers: [1, 2, 3, 4, 5]}
      assert {:ok, 15} = BaseTool.run(tool)
    end

    test "calculates average" do
      tool = %ListProcessor{operation: "average", numbers: [10, 20, 30]}
      assert {:ok, 20.0} = BaseTool.run(tool)
    end

    test "handles empty list for average" do
      tool = %ListProcessor{operation: "average", numbers: []}
      assert {:error, "Cannot calculate average of empty list"} = BaseTool.run(tool)
    end

    test "finds minimum" do
      tool = %ListProcessor{operation: "min", numbers: [5, 2, 8, 1, 9]}
      assert {:ok, 1} = BaseTool.run(tool)
    end

    test "finds maximum" do
      tool = %ListProcessor{operation: "max", numbers: [5, 2, 8, 1, 9]}
      assert {:ok, 9} = BaseTool.run(tool)
    end

    test "sorts ascending" do
      tool = %ListProcessor{operation: "sort_asc", numbers: [3, 1, 4, 1, 5, 9, 2, 6]}
      assert {:ok, [1, 1, 2, 3, 4, 5, 6, 9]} = BaseTool.run(tool)
    end

    test "sorts descending" do
      tool = %ListProcessor{operation: "sort_desc", numbers: [3, 1, 4, 1, 5, 9, 2, 6]}
      assert {:ok, [9, 6, 5, 4, 3, 2, 1, 1]} = BaseTool.run(tool)
    end

    test "counts elements" do
      tool = %ListProcessor{operation: "count", numbers: [1, 2, 3, 4, 5]}
      assert {:ok, 5} = BaseTool.run(tool)
    end

    test "handles empty list for min/max with error" do
      tool_min = %ListProcessor{operation: "min", numbers: []}
      tool_max = %ListProcessor{operation: "max", numbers: []}

      assert {:error, _} = BaseTool.run(tool_min)
      assert {:error, _} = BaseTool.run(tool_max)
    end
  end
end
