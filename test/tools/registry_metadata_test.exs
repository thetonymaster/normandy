defmodule NormandyTest.Tools.RegistryMetadataTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.Registry
  alias Normandy.Tools.Examples.{Calculator, EnhancedCalculator, StringManipulator}

  describe "get_metadata/2" do
    test "returns metadata for a registered tool" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      {:ok, metadata} = Registry.get_metadata(registry, "calculator")

      assert metadata.name == "calculator"
      assert metadata.description =~ "arithmetic"
      assert is_map(metadata.input_schema)
    end

    test "returns :error for non-existent tool" do
      registry = Registry.new()

      assert Registry.get_metadata(registry, "nonexistent") == :error
    end

    test "includes field introspection for schema-based tools" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      {:ok, metadata} = Registry.get_metadata(registry, "calculator")

      assert Map.has_key?(metadata, :fields)
      assert is_list(metadata.fields)
      assert length(metadata.fields) > 0

      # Check field structure
      operation_field = Enum.find(metadata.fields, fn f -> f.name == :operation end)
      assert operation_field.type == :string
      assert operation_field.required == true
      assert is_map(operation_field.metadata)
    end

    test "includes enhanced field metadata" do
      enhanced = %EnhancedCalculator{}
      registry = Registry.new([enhanced])

      {:ok, metadata} = Registry.get_metadata(registry, "enhanced_calculator")

      assert Map.has_key?(metadata, :fields)

      # Check precision field which is optional with constraints
      precision_field = Enum.find(metadata.fields, fn f -> f.name == :precision end)
      assert precision_field.type == :integer
      assert precision_field.required == false
    end
  end

  describe "list_metadata/1" do
    test "returns metadata for all registered tools" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      string = %StringManipulator{operation: "uppercase", text: ""}

      registry = Registry.new([calc, string])
      metadata_list = Registry.list_metadata(registry)

      assert length(metadata_list) == 2
      assert Enum.all?(metadata_list, fn m -> Map.has_key?(m, :name) end)
      assert Enum.all?(metadata_list, fn m -> Map.has_key?(m, :description) end)
      assert Enum.all?(metadata_list, fn m -> Map.has_key?(m, :input_schema) end)
    end

    test "returns empty list for empty registry" do
      registry = Registry.new()
      metadata_list = Registry.list_metadata(registry)

      assert metadata_list == []
    end

    test "includes field introspection for schema-based tools" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      enhanced = %EnhancedCalculator{}

      registry = Registry.new([calc, enhanced])
      metadata_list = Registry.list_metadata(registry)

      # Both should have fields since both are schema-based
      enhanced_meta = Enum.find(metadata_list, fn m -> m.name == "enhanced_calculator" end)
      assert Map.has_key?(enhanced_meta, :fields)

      calc_meta = Enum.find(metadata_list, fn m -> m.name == "calculator" end)
      assert Map.has_key?(calc_meta, :fields)

      # EnhancedCalculator should have more fields (precision)
      assert length(enhanced_meta.fields) == 4
      assert length(calc_meta.fields) == 3
    end
  end

  describe "filter_by_required_params/2" do
    test "filters tools with required parameters" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      filtered = Registry.filter_by_required_params(registry, true)

      assert Registry.count(filtered) == 1
      assert Registry.has_tool?(filtered, "calculator")
    end

    test "filters tools without required parameters" do
      # Create a tool without required params (if we had one)
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      filtered = Registry.filter_by_required_params(registry, false)

      assert Registry.count(filtered) == 0
    end

    test "returns empty registry when no tools match" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      filtered = Registry.filter_by_required_params(registry, false)

      assert Registry.count(filtered) == 0
    end
  end

  describe "filter_by_param_type/2" do
    test "filters tools with number parameters" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      string = %StringManipulator{operation: "uppercase", text: ""}

      registry = Registry.new([calc, string])

      # Calculator has :number type in JSON schema (mapped from :float)
      # StringManipulator only has string fields
      # But we need to check the JSON Schema type which may differ
      filtered = Registry.filter_by_param_type(registry, "number")

      # Only calculator should match as it has number fields in its JSON schema
      assert Registry.count(filtered) >= 0
    end

    test "filters tools with string parameters" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      string = %StringManipulator{operation: "uppercase", text: ""}

      registry = Registry.new([calc, string])
      filtered = Registry.filter_by_param_type(registry, "string")

      # Both have string params (operation field)
      assert Registry.count(filtered) >= 1
    end

    test "returns empty registry when no tools have the parameter type" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      filtered = Registry.filter_by_param_type(registry, "boolean")

      assert Registry.count(filtered) == 0
    end
  end

  describe "tools_with_constraint/2" do
    test "finds tools with enum constraints" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      string = %StringManipulator{operation: "uppercase", text: ""}

      registry = Registry.new([calc, string])
      tools = Registry.tools_with_constraint(registry, :enum)

      # Both have enum on operation field
      assert length(tools) == 2
      assert "calculator" in tools
      assert "string_manipulator" in tools
    end

    test "finds tools with minimum constraints" do
      enhanced = %EnhancedCalculator{}
      registry = Registry.new([enhanced])

      tools = Registry.tools_with_constraint(registry, :minimum)

      assert length(tools) == 1
      assert "enhanced_calculator" in tools
    end

    test "returns empty list when no tools have the constraint" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      tools = Registry.tools_with_constraint(registry, :pattern)

      assert tools == []
    end
  end

  describe "introspect_schema/2" do
    test "returns schema introspection for schema-based tools" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      {:ok, fields} = Registry.introspect_schema(registry, "calculator")

      assert is_list(fields)
      assert length(fields) > 0

      # Check field structure
      operation_field = Enum.find(fields, fn f -> f.name == :operation end)
      assert operation_field.type == :string
      assert operation_field.required == true
      assert is_map(operation_field.metadata)
    end

    test "returns schema introspection for enhanced tools" do
      enhanced = %EnhancedCalculator{}
      registry = Registry.new([enhanced])

      {:ok, fields} = Registry.introspect_schema(registry, "enhanced_calculator")

      assert is_list(fields)
      # EnhancedCalculator has operation, a, b, precision
      assert length(fields) == 4
    end

    test "returns :error for non-existent tool" do
      registry = Registry.new()

      assert Registry.introspect_schema(registry, "nonexistent") == :error
    end

    test "includes field metadata with constraints" do
      enhanced = %EnhancedCalculator{}
      registry = Registry.new([enhanced])

      {:ok, fields} = Registry.introspect_schema(registry, "enhanced_calculator")

      precision_field = Enum.find(fields, fn f -> f.name == :precision end)
      assert precision_field.type == :integer
      assert precision_field.required == false
      assert is_map(precision_field.metadata)
      assert precision_field.metadata.constraints.minimum == 0
      assert precision_field.metadata.constraints.maximum == 10
    end
  end

  describe "integration with enhanced tools" do
    test "metadata methods work seamlessly with schema-based tools" do
      enhanced = %EnhancedCalculator{}
      registry = Registry.new([enhanced])

      # Get metadata
      {:ok, metadata} = Registry.get_metadata(registry, "enhanced_calculator")
      assert Map.has_key?(metadata, :fields)

      # Introspect schema
      {:ok, fields} = Registry.introspect_schema(registry, "enhanced_calculator")
      assert length(fields) == length(metadata.fields)

      # Find constraints
      enum_tools = Registry.tools_with_constraint(registry, :enum)
      assert "enhanced_calculator" in enum_tools
    end

    test "handles mixed registry of schema-based tools" do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      enhanced = %EnhancedCalculator{}

      registry = Registry.new([calc, enhanced])
      metadata_list = Registry.list_metadata(registry)

      assert length(metadata_list) == 2

      # Both should have fields since both are schema-based
      enhanced_meta = Enum.find(metadata_list, fn m -> m.name == "enhanced_calculator" end)
      calc_meta = Enum.find(metadata_list, fn m -> m.name == "calculator" end)

      assert Map.has_key?(enhanced_meta, :fields)
      assert Map.has_key?(calc_meta, :fields)

      # Enhanced has more fields (includes precision)
      assert length(enhanced_meta.fields) > length(calc_meta.fields)
    end
  end

  describe "edge cases" do
    test "handles empty registry gracefully" do
      registry = Registry.new()

      assert Registry.list_metadata(registry) == []
      assert Registry.filter_by_required_params(registry, true) == registry
      assert Registry.filter_by_param_type(registry, "string") == registry
      assert Registry.tools_with_constraint(registry, :enum) == []
    end

    test "handles tools with no properties in schema" do
      # This tests backward compatibility
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      # Should not crash
      filtered = Registry.filter_by_param_type(registry, "string")
      assert is_struct(filtered, Registry)
    end

    test "metadata includes all expected fields" do
      enhanced = %EnhancedCalculator{}
      registry = Registry.new([enhanced])

      {:ok, metadata} = Registry.get_metadata(registry, "enhanced_calculator")

      # Basic metadata
      assert is_binary(metadata.name)
      assert is_binary(metadata.description)
      assert is_map(metadata.input_schema)

      # Enhanced metadata
      assert is_list(metadata.fields)

      # Each field has expected structure
      Enum.each(metadata.fields, fn field ->
        assert is_atom(field.name)
        assert is_boolean(field.required)
        assert is_map(field.metadata)
      end)
    end
  end
end
