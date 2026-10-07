defmodule NormandyTest.Tools.ToolsetMetadataTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.Examples.{Calculator, EnhancedCalculator, StringManipulator}
  alias Normandy.Tools.Toolset

  describe "fetch_metadata/2" do
    test "returns metadata for a registered tool" do
      calc = %Calculator{}
      registry = Toolset.new([calc])

      {:ok, metadata} = Toolset.fetch_metadata(registry, "calculator")

      assert metadata.name == "calculator"
      assert metadata.description =~ "arithmetic"
      assert is_map(metadata.input_schema)
    end

    test "returns :error for non-existent tool" do
      registry = Toolset.new()

      assert Toolset.fetch_metadata(registry, "nonexistent") == :error
    end

    test "includes field introspection for schema-based tools" do
      calc = %Calculator{}
      registry = Toolset.new([calc])

      {:ok, metadata} = Toolset.fetch_metadata(registry, "calculator")

      assert Map.has_key?(metadata, :fields)
      assert is_list(metadata.fields)
      assert metadata.fields != []

      # Check field structure
      operation_field = Enum.find(metadata.fields, fn f -> f.name == :operation end)
      assert operation_field.type == :string
      assert operation_field.required == true
      assert is_map(operation_field.metadata)
    end

    test "includes enhanced field metadata" do
      enhanced = %EnhancedCalculator{}
      registry = Toolset.new([enhanced])

      {:ok, metadata} = Toolset.fetch_metadata(registry, "enhanced_calculator")

      assert Map.has_key?(metadata, :fields)

      # Check precision field which is optional with constraints
      precision_field = Enum.find(metadata.fields, fn f -> f.name == :precision end)
      assert precision_field.type == :integer
      assert precision_field.required == false
    end
  end

  describe "list_metadata/1" do
    test "returns metadata for all registered tools" do
      calc = %Calculator{}
      string = %StringManipulator{}

      registry = Toolset.new([calc, string])
      metadata_list = Toolset.list_metadata(registry)

      assert length(metadata_list) == 2
      assert Enum.all?(metadata_list, fn m -> Map.has_key?(m, :name) end)
      assert Enum.all?(metadata_list, fn m -> Map.has_key?(m, :description) end)
      assert Enum.all?(metadata_list, fn m -> Map.has_key?(m, :input_schema) end)
    end

    test "returns empty list for empty registry" do
      registry = Toolset.new()
      metadata_list = Toolset.list_metadata(registry)

      assert metadata_list == []
    end

    test "includes field introspection for schema-based tools" do
      calc = %Calculator{}
      enhanced = %EnhancedCalculator{}

      registry = Toolset.new([calc, enhanced])
      metadata_list = Toolset.list_metadata(registry)

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

  describe "introspect_schema/2" do
    test "returns schema introspection for schema-based tools" do
      calc = %Calculator{}
      registry = Toolset.new([calc])

      {:ok, fields} = Toolset.introspect_schema(registry, "calculator")

      assert is_list(fields)
      assert fields != []

      # Check field structure
      operation_field = Enum.find(fields, fn f -> f.name == :operation end)
      assert operation_field.type == :string
      assert operation_field.required == true
      assert is_map(operation_field.metadata)
    end

    test "returns schema introspection for enhanced tools" do
      enhanced = %EnhancedCalculator{}
      registry = Toolset.new([enhanced])

      {:ok, fields} = Toolset.introspect_schema(registry, "enhanced_calculator")

      assert is_list(fields)
      # EnhancedCalculator has operation, a, b, precision
      assert length(fields) == 4
    end

    test "returns :error for non-existent tool" do
      registry = Toolset.new()

      assert Toolset.introspect_schema(registry, "nonexistent") == :error
    end

    test "includes field metadata with constraints" do
      enhanced = %EnhancedCalculator{}
      registry = Toolset.new([enhanced])

      {:ok, fields} = Toolset.introspect_schema(registry, "enhanced_calculator")

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
      registry = Toolset.new([enhanced])

      # Get metadata
      {:ok, metadata} = Toolset.fetch_metadata(registry, "enhanced_calculator")
      assert Map.has_key?(metadata, :fields)

      # Introspect schema
      {:ok, fields} = Toolset.introspect_schema(registry, "enhanced_calculator")
      assert length(fields) == length(metadata.fields)
    end

    test "handles mixed registry of schema-based tools" do
      calc = %Calculator{}
      enhanced = %EnhancedCalculator{}

      registry = Toolset.new([calc, enhanced])
      metadata_list = Toolset.list_metadata(registry)

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
      registry = Toolset.new()

      assert Toolset.list_metadata(registry) == []
    end

    test "the 1.x schema filters are gone" do
      Code.ensure_loaded!(Toolset)
      refute function_exported?(Toolset, :filter_by_required_params, 2)
      refute function_exported?(Toolset, :filter_by_param_type, 2)
      refute function_exported?(Toolset, :tools_with_constraint, 2)
    end

    test "metadata includes all expected fields" do
      enhanced = %EnhancedCalculator{}
      registry = Toolset.new([enhanced])

      {:ok, metadata} = Toolset.fetch_metadata(registry, "enhanced_calculator")

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
