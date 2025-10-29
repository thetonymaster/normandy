defmodule NormandyTest.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.Registry
  alias Normandy.Tools.Examples.{Calculator, StringManipulator, ListProcessor}

  describe "Registry.new/0" do
    test "creates empty registry" do
      registry = Registry.new()
      assert %Registry{tools: tools} = registry
      assert tools == %{}
      assert Registry.count(registry) == 0
    end
  end

  describe "Registry.new/1" do
    test "creates registry with tools" do
      tools = [
        %Calculator{operation: "add", a: 0, b: 0},
        %StringManipulator{operation: "uppercase", text: ""}
      ]

      registry = Registry.new(tools)
      assert Registry.count(registry) == 2
      assert Registry.has_tool?(registry, "calculator")
      assert Registry.has_tool?(registry, "string_manipulator")
    end
  end

  describe "Registry.register/2" do
    test "registers a tool" do
      registry = Registry.new()
      tool = %Calculator{operation: "add", a: 1, b: 2}

      registry = Registry.register(registry, tool)

      assert Registry.count(registry) == 1
      assert {:ok, ^tool} = Registry.get(registry, "calculator")
    end

    test "replaces existing tool with same name" do
      tool1 = %Calculator{operation: "add", a: 1, b: 2}
      tool2 = %Calculator{operation: "multiply", a: 3, b: 4}

      registry =
        Registry.new()
        |> Registry.register(tool1)
        |> Registry.register(tool2)

      assert Registry.count(registry) == 1
      assert {:ok, ^tool2} = Registry.get(registry, "calculator")
    end
  end

  describe "Registry.get/2" do
    test "retrieves registered tool" do
      tool = %Calculator{operation: "add", a: 5, b: 3}
      registry = Registry.new([tool])

      assert {:ok, ^tool} = Registry.get(registry, "calculator")
    end

    test "returns error for nonexistent tool" do
      registry = Registry.new()
      assert :error = Registry.get(registry, "nonexistent")
    end
  end

  describe "Registry.get!/2" do
    test "retrieves registered tool" do
      tool = %Calculator{operation: "add", a: 5, b: 3}
      registry = Registry.new([tool])

      assert ^tool = Registry.get!(registry, "calculator")
    end

    test "raises for nonexistent tool" do
      registry = Registry.new()

      assert_raise RuntimeError, "Tool 'nonexistent' not found in registry", fn ->
        Registry.get!(registry, "nonexistent")
      end
    end
  end

  describe "Registry.unregister/2" do
    test "removes tool from registry" do
      tool = %Calculator{operation: "add", a: 1, b: 2}
      registry = Registry.new([tool])

      assert Registry.count(registry) == 1

      registry = Registry.unregister(registry, "calculator")

      assert Registry.count(registry) == 0
      assert :error = Registry.get(registry, "calculator")
    end

    test "does nothing if tool doesn't exist" do
      registry = Registry.new()
      registry = Registry.unregister(registry, "nonexistent")
      assert Registry.count(registry) == 0
    end
  end

  describe "Registry.list/1" do
    test "returns all registered tools" do
      tool1 = %Calculator{operation: "add", a: 1, b: 2}
      tool2 = %StringManipulator{operation: "uppercase", text: "hello"}

      registry = Registry.new([tool1, tool2])
      tools = Registry.list(registry)

      assert length(tools) == 2
      assert tool1 in tools
      assert tool2 in tools
    end

    test "returns empty list for empty registry" do
      registry = Registry.new()
      assert [] = Registry.list(registry)
    end
  end

  describe "Registry.list_names/1" do
    test "returns all tool names" do
      tools = [
        %Calculator{operation: "add", a: 0, b: 0},
        %StringManipulator{operation: "uppercase", text: ""},
        %ListProcessor{operation: "sum", numbers: []}
      ]

      registry = Registry.new(tools)
      names = Registry.list_names(registry)

      assert length(names) == 3
      assert "calculator" in names
      assert "string_manipulator" in names
      assert "list_processor" in names
    end
  end

  describe "Registry.has_tool?/2" do
    test "returns true for registered tool" do
      tool = %Calculator{operation: "add", a: 1, b: 2}
      registry = Registry.new([tool])

      assert Registry.has_tool?(registry, "calculator") == true
    end

    test "returns false for unregistered tool" do
      registry = Registry.new()
      assert Registry.has_tool?(registry, "calculator") == false
    end
  end

  describe "Registry.to_tool_schemas/1" do
    test "generates tool schemas for LLM" do
      tool = %Calculator{operation: "add", a: 1, b: 2}
      registry = Registry.new([tool])

      schemas = Registry.to_tool_schemas(registry)

      assert length(schemas) == 1
      assert [schema] = schemas

      assert schema.name == "calculator"

      assert schema.description ==
               "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers"

      assert schema.input_schema.type == :object
      assert Map.has_key?(schema.input_schema.properties, :operation)
    end

    test "generates multiple tool schemas" do
      tools = [
        %Calculator{operation: "add", a: 0, b: 0},
        %StringManipulator{operation: "uppercase", text: ""}
      ]

      registry = Registry.new(tools)
      schemas = Registry.to_tool_schemas(registry)

      assert length(schemas) == 2
      names = Enum.map(schemas, & &1.name)
      assert "calculator" in names
      assert "string_manipulator" in names
    end
  end
end
