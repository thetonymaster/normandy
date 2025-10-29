defmodule Normandy.Tools.SchemaBaseToolTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.Examples.EnhancedCalculator
  alias Normandy.Tools.BaseTool
  alias Normandy.Schema.ValidationError

  describe "tool_schema macro" do
    test "defines a struct with specified fields" do
      assert %EnhancedCalculator{} == %EnhancedCalculator{
               operation: nil,
               a: nil,
               b: nil,
               precision: 2
             }
    end

    test "applies default values from schema" do
      calc = %EnhancedCalculator{}
      assert calc.precision == 2
    end

    test "allows struct creation with field values" do
      calc = %EnhancedCalculator{operation: "add", a: 5.0, b: 3.0}
      assert calc.operation == "add"
      assert calc.a == 5.0
      assert calc.b == 3.0
      assert calc.precision == 2
    end
  end

  describe "validate/1" do
    test "validates correct input successfully" do
      params = %{operation: "add", a: 5, b: 3}

      assert {:ok, calc} = EnhancedCalculator.validate(params)
      assert %EnhancedCalculator{} = calc
      assert calc.operation == "add"
      assert calc.a == 5.0
      assert calc.b == 3.0
      assert calc.precision == 2
    end

    test "applies default values during validation" do
      params = %{operation: "multiply", a: 4, b: 7}

      assert {:ok, calc} = EnhancedCalculator.validate(params)
      assert calc.precision == 2
    end

    test "allows overriding default values" do
      params = %{operation: "divide", a: 10, b: 3, precision: 5}

      assert {:ok, calc} = EnhancedCalculator.validate(params)
      assert calc.precision == 5
    end

    test "returns error for missing required fields" do
      params = %{operation: "add", b: 3}

      assert {:error, errors} = EnhancedCalculator.validate(params)
      assert is_list(errors)
      assert Enum.any?(errors, fn error -> error.path == [:a] end)
    end

    test "returns error for invalid enum value" do
      params = %{operation: "invalid_op", a: 5, b: 3}

      assert {:error, errors} = EnhancedCalculator.validate(params)
      assert is_list(errors)
      assert Enum.any?(errors, fn error -> error.path == [:operation] end)
    end

    test "returns error for precision outside minimum/maximum range" do
      params = %{operation: "add", a: 5, b: 3, precision: 15}

      assert {:error, errors} = EnhancedCalculator.validate(params)
      assert is_list(errors)
      assert Enum.any?(errors, fn error -> error.path == [:precision] end)
    end

    test "returns error for precision below minimum" do
      params = %{operation: "add", a: 5, b: 3, precision: -1}

      assert {:error, errors} = EnhancedCalculator.validate(params)
      assert is_list(errors)
      assert Enum.any?(errors, fn error -> error.path == [:precision] end)
    end

    test "accepts integers for float fields (validator allows numbers)" do
      params = %{operation: "add", a: 5, b: 3}

      assert {:ok, calc} = EnhancedCalculator.validate(params)
      # Validator accepts both integers and floats for :float type
      assert is_number(calc.a)
      assert is_number(calc.b)
      assert calc.a == 5
      assert calc.b == 3
    end

    test "rejects string inputs for numeric fields" do
      params = %{operation: "add", a: "5.5", b: "3.2"}

      # Validator does not perform string-to-number parsing
      assert {:error, errors} = EnhancedCalculator.validate(params)
      assert is_list(errors)
      assert Enum.any?(errors, fn error -> error.path == [:a] end)
      assert Enum.any?(errors, fn error -> error.path == [:b] end)
    end
  end

  describe "validate!/1" do
    test "returns validated struct on success" do
      params = %{operation: "add", a: 5, b: 3}

      assert %EnhancedCalculator{} = calc = EnhancedCalculator.validate!(params)
      assert calc.operation == "add"
      assert calc.a == 5.0
      assert calc.b == 3.0
    end

    test "raises ValidationError on invalid input" do
      params = %{operation: "invalid", a: 5, b: 3}

      assert_raise ValidationError, fn ->
        EnhancedCalculator.validate!(params)
      end
    end

    test "raises ValidationError with error details" do
      params = %{operation: "add", b: 3}

      assert_raise ValidationError, ~r/Tool input validation failed/, fn ->
        EnhancedCalculator.validate!(params)
      end
    end
  end

  describe "execute/1" do
    test "executes addition correctly" do
      calc = %EnhancedCalculator{operation: "add", a: 5.5, b: 3.2, precision: 2}

      assert {:ok, result} = EnhancedCalculator.execute(calc)
      assert result == 8.7
    end

    test "executes subtraction correctly" do
      calc = %EnhancedCalculator{operation: "subtract", a: 10.0, b: 3.5, precision: 2}

      assert {:ok, result} = EnhancedCalculator.execute(calc)
      assert result == 6.5
    end

    test "executes multiplication correctly" do
      calc = %EnhancedCalculator{operation: "multiply", a: 4.0, b: 7.0, precision: 2}

      assert {:ok, result} = EnhancedCalculator.execute(calc)
      assert result == 28.0
    end

    test "executes division correctly" do
      calc = %EnhancedCalculator{operation: "divide", a: 10.0, b: 3.0, precision: 2}

      assert {:ok, result} = EnhancedCalculator.execute(calc)
      assert result == 3.33
    end

    test "respects precision parameter" do
      calc = %EnhancedCalculator{operation: "divide", a: 10.0, b: 3.0, precision: 5}

      assert {:ok, result} = EnhancedCalculator.execute(calc)
      assert result == 3.33333
    end

    test "returns error for division by zero" do
      calc = %EnhancedCalculator{operation: "divide", a: 10.0, b: 0.0, precision: 2}

      assert {:error, "Cannot divide by zero"} = EnhancedCalculator.execute(calc)
    end
  end

  describe "BaseTool protocol implementation" do
    test "implements tool_name/1" do
      calc = %EnhancedCalculator{}
      assert BaseTool.tool_name(calc) == "enhanced_calculator"
    end

    test "implements tool_description/1" do
      calc = %EnhancedCalculator{}

      assert BaseTool.tool_description(calc) ==
               "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers with validation"
    end

    test "implements input_schema/1 and returns JSON Schema" do
      calc = %EnhancedCalculator{}
      schema = BaseTool.input_schema(calc)

      assert is_map(schema)
      assert schema[:type] == :object
      assert is_map(schema[:properties])
      assert Map.has_key?(schema[:properties], :operation)
      assert Map.has_key?(schema[:properties], :a)
      assert Map.has_key?(schema[:properties], :b)
      assert Map.has_key?(schema[:properties], :precision)
    end

    test "input_schema includes field descriptions" do
      calc = %EnhancedCalculator{}
      schema = BaseTool.input_schema(calc)

      assert schema[:properties][:operation][:description] ==
               "The arithmetic operation to perform"

      assert schema[:properties][:a][:description] == "The first number (operand)"
      assert schema[:properties][:b][:description] == "The second number (operand)"

      assert schema[:properties][:precision][:description] ==
               "Number of decimal places in result"
    end

    test "input_schema includes enum constraint" do
      calc = %EnhancedCalculator{}
      schema = BaseTool.input_schema(calc)

      assert schema[:properties][:operation][:enum] == [
               "add",
               "subtract",
               "multiply",
               "divide"
             ]
    end

    test "input_schema includes numeric constraints" do
      calc = %EnhancedCalculator{}
      schema = BaseTool.input_schema(calc)

      assert schema[:properties][:precision][:minimum] == 0
      assert schema[:properties][:precision][:maximum] == 10
    end

    test "input_schema includes required fields" do
      calc = %EnhancedCalculator{}
      schema = BaseTool.input_schema(calc)

      assert :operation in schema[:required]
      assert :a in schema[:required]
      assert :b in schema[:required]
      refute :precision in schema[:required]
    end

    test "implements run/1 and executes tool" do
      calc = %EnhancedCalculator{operation: "add", a: 5.0, b: 3.0, precision: 2}

      assert {:ok, result} = BaseTool.run(calc)
      assert result == 8.0
    end

    test "run/1 returns errors from execute/1" do
      calc = %EnhancedCalculator{operation: "divide", a: 10.0, b: 0.0, precision: 2}

      assert {:error, "Cannot divide by zero"} = BaseTool.run(calc)
    end
  end

  describe "integration: validate and execute workflow" do
    test "validates input, then executes successfully" do
      params = %{operation: "multiply", a: 6.0, b: 7.0}

      assert {:ok, calc} = EnhancedCalculator.validate(params)
      assert {:ok, result} = EnhancedCalculator.execute(calc)
      assert result == 42.0
    end

    test "validates input, then executes through BaseTool protocol" do
      params = %{operation: "subtract", a: 20.0, b: 8.0, precision: 1}

      assert {:ok, calc} = EnhancedCalculator.validate(params)
      assert {:ok, result} = BaseTool.run(calc)
      assert result == 12.0
    end

    test "validation prevents invalid inputs from reaching execute" do
      params = %{operation: "invalid_op", a: 5, b: 3}

      assert {:error, _errors} = EnhancedCalculator.validate(params)
    end

    test "complete workflow with validate! and execute" do
      params = %{operation: "divide", a: 22.0, b: 7.0, precision: 3}

      calc = EnhancedCalculator.validate!(params)
      assert {:ok, result} = EnhancedCalculator.execute(calc)
      assert result == 3.143
    end
  end

  describe "schema introspection" do
    test "schema module defines __schema__/1" do
      assert function_exported?(EnhancedCalculator, :__schema__, 1)
    end

    test "can introspect field list" do
      fields = EnhancedCalculator.__schema__(:fields)
      assert :operation in fields
      assert :a in fields
      assert :b in fields
      assert :precision in fields
    end

    test "can introspect field types" do
      assert EnhancedCalculator.__schema__(:type, :operation) == :string
      assert EnhancedCalculator.__schema__(:type, :a) == :float
      assert EnhancedCalculator.__schema__(:type, :b) == :float
      assert EnhancedCalculator.__schema__(:type, :precision) == :integer
    end

    test "can introspect specification" do
      spec = EnhancedCalculator.__schema__(:specification)
      assert is_map(spec)
      assert spec[:type] == :object
    end
  end
end
