defmodule NormandyTest.Tools.ExamplesTest do
  use ExUnit.Case, async: true

  alias Normandy.Tool
  alias Normandy.Tools.{Context, Input}
  alias Normandy.Tools.Examples.{Calculator, ListProcessor, StringManipulator}

  # What the dispatcher does: validate the input, then run the tool with it.
  defp run_tool({tool, input}) do
    case Input.validate(tool, input) do
      {:ok, validated} -> Tool.run(tool, %Context{tool_call_id: "t", input: validated})
      {:error, errors} -> {:error, Input.message(errors)}
    end
  end

  test "the example tools are test fixtures, not part of the library" do
    for name <- ~w(Calculator EnhancedCalculator ListProcessor StringManipulator) do
      module = Module.concat(Normandy.Tools.Examples, name)
      assert Code.ensure_loaded?(module), "#{inspect(module)} is not compiled in the test env"
      source = module.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()

      assert source =~ "/test/support/tools/",
             "#{inspect(module)} is compiled from #{source}, expected test/support/tools/"
    end

    refute Code.ensure_loaded?(Normandy.Tools.Examples.Weather),
           "Normandy.Tools.Examples.Weather is still compiled from lib/"
  end

  describe "Calculator tool" do
    test "performs addition" do
      tool = {%Calculator{}, %{operation: "add", a: 10, b: 5}}
      assert {:ok, 15.0} = run_tool(tool)
    end

    test "performs subtraction" do
      tool = {%Calculator{}, %{operation: "subtract", a: 10, b: 3}}
      assert {:ok, 7.0} = run_tool(tool)
    end

    test "performs multiplication" do
      tool = {%Calculator{}, %{operation: "multiply", a: 6, b: 7}}
      assert {:ok, 42.0} = run_tool(tool)
    end

    test "performs division" do
      tool = {%Calculator{}, %{operation: "divide", a: 20, b: 4}}
      assert {:ok, 5.0} = run_tool(tool)
    end

    test "handles division by zero" do
      tool = {%Calculator{}, %{operation: "divide", a: 10, b: 0}}
      assert {:error, "Cannot divide by zero"} = run_tool(tool)
    end

    test "an operation outside the enum is refused before the tool runs" do
      tool = {%Calculator{}, %{operation: "power", a: 2, b: 3}}

      assert {:error, ~s(operation must be one of ["add", "subtract", "multiply", "divide"])} =
               run_tool(tool)
    end

    test "provides correct metadata" do
      tool = %Calculator{}
      assert Tool.name(tool) == "calculator"
      assert Tool.description(tool) =~ "arithmetic"

      schema = Tool.input_schema(tool)
      assert schema.type == :object
      assert Map.has_key?(schema.properties, :operation)
    end
  end

  describe "StringManipulator tool" do
    test "converts to uppercase" do
      tool = {%StringManipulator{}, %{operation: "uppercase", text: "hello world"}}
      assert {:ok, "HELLO WORLD"} = run_tool(tool)
    end

    test "converts to lowercase" do
      tool = {%StringManipulator{}, %{operation: "lowercase", text: "HELLO WORLD"}}
      assert {:ok, "hello world"} = run_tool(tool)
    end

    test "reverses string" do
      tool = {%StringManipulator{}, %{operation: "reverse", text: "hello"}}
      assert {:ok, "olleh"} = run_tool(tool)
    end

    test "splits string with delimiter" do
      tool = {%StringManipulator{}, %{operation: "split", text: "a,b,c", delimiter: ","}}
      assert {:ok, ["a", "b", "c"]} = run_tool(tool)
    end

    test "splits string without delimiter (whitespace)" do
      tool = {%StringManipulator{}, %{operation: "split", text: "hello world test"}}
      assert {:ok, ["hello", "world", "test"]} = run_tool(tool)
    end

    test "truncates string" do
      tool = {%StringManipulator{}, %{operation: "truncate", text: "hello world", count: 5}}
      assert {:ok, "hello"} = run_tool(tool)
    end

    test "requires count for truncate" do
      tool = {%StringManipulator{}, %{operation: "truncate", text: "hello"}}
      assert {:error, error} = run_tool(tool)
      assert error =~ "count"
    end

    test "returns string length" do
      tool = {%StringManipulator{}, %{operation: "length", text: "hello"}}
      assert {:ok, 5} = run_tool(tool)
    end

    test "handles unknown operation" do
      tool = {%StringManipulator{}, %{operation: "invalid", text: "test"}}
      assert {:error, error} = run_tool(tool)
      assert error =~ "Unknown operation"
    end
  end

  describe "ListProcessor tool" do
    test "calculates sum" do
      tool = {%ListProcessor{}, %{operation: "sum", numbers: [1, 2, 3, 4, 5]}}
      assert {:ok, 15} = run_tool(tool)
    end

    test "calculates average" do
      tool = {%ListProcessor{}, %{operation: "average", numbers: [10, 20, 30]}}
      assert {:ok, 20.0} = run_tool(tool)
    end

    test "handles empty list for average" do
      tool = {%ListProcessor{}, %{operation: "average", numbers: []}}
      assert {:error, "Cannot calculate average of empty list"} = run_tool(tool)
    end

    test "finds minimum" do
      tool = {%ListProcessor{}, %{operation: "min", numbers: [5, 2, 8, 1, 9]}}
      assert {:ok, 1} = run_tool(tool)
    end

    test "finds maximum" do
      tool = {%ListProcessor{}, %{operation: "max", numbers: [5, 2, 8, 1, 9]}}
      assert {:ok, 9} = run_tool(tool)
    end

    test "sorts ascending" do
      tool = {%ListProcessor{}, %{operation: "sort_asc", numbers: [3, 1, 4, 1, 5, 9, 2, 6]}}
      assert {:ok, [1, 1, 2, 3, 4, 5, 6, 9]} = run_tool(tool)
    end

    test "sorts descending" do
      tool = {%ListProcessor{}, %{operation: "sort_desc", numbers: [3, 1, 4, 1, 5, 9, 2, 6]}}
      assert {:ok, [9, 6, 5, 4, 3, 2, 1, 1]} = run_tool(tool)
    end

    test "counts elements" do
      tool = {%ListProcessor{}, %{operation: "count", numbers: [1, 2, 3, 4, 5]}}
      assert {:ok, 5} = run_tool(tool)
    end

    test "handles empty list for min/max with error" do
      tool_min = {%ListProcessor{}, %{operation: "min", numbers: []}}
      tool_max = {%ListProcessor{}, %{operation: "max", numbers: []}}

      assert {:error, _} = run_tool(tool_min)
      assert {:error, _} = run_tool(tool_max)
    end
  end
end
