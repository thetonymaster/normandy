defmodule NormandyTest.Tools.ToolsetTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.Examples.{Calculator, ListProcessor, StringManipulator}
  alias Normandy.Tools.Toolset

  describe "Toolset.new/0" do
    test "creates empty registry" do
      registry = Toolset.new()
      assert %Toolset{tools: tools} = registry
      assert tools == %{}
      assert Toolset.count(registry) == 0
    end
  end

  describe "Toolset.new/1" do
    test "creates registry with tools" do
      tools = [
        %Calculator{operation: "add", a: 0, b: 0},
        %StringManipulator{operation: "uppercase", text: ""}
      ]

      registry = Toolset.new(tools)
      assert Toolset.count(registry) == 2
      assert Toolset.has_tool?(registry, "calculator")
      assert Toolset.has_tool?(registry, "string_manipulator")
    end
  end

  describe "Toolset.register/2" do
    test "registers a tool" do
      registry = Toolset.new()
      tool = %Calculator{operation: "add", a: 1, b: 2}

      registry = Toolset.register(registry, tool)

      assert Toolset.count(registry) == 1
      assert {:ok, ^tool} = Toolset.fetch(registry, "calculator")
    end

    test "a second tool with the same name raises" do
      registry = Toolset.new([%Calculator{operation: "add", a: 1, b: 2}])

      assert_raise ArgumentError, ~r/"calculator" is already registered/, fn ->
        Toolset.register(registry, %Calculator{operation: "multiply", a: 3, b: 4})
      end
    end

    test "replace: true replaces the tool with the same name" do
      tool1 = %Calculator{operation: "add", a: 1, b: 2}
      tool2 = %Calculator{operation: "multiply", a: 3, b: 4}

      registry =
        Toolset.new()
        |> Toolset.register(tool1)
        |> Toolset.register(tool2, replace: true)

      assert Toolset.count(registry) == 1
      assert {:ok, ^tool2} = Toolset.fetch(registry, "calculator")
    end

    test "a name the API would reject raises at registration" do
      dotted = %Normandy.MCP.ToolWrapper{tool: %{name: "web.search"}}

      assert_raise ArgumentError, ~r/"web.search" is not a valid tool name/, fn ->
        Toolset.register(Toolset.new(), dotted)
      end

      too_long = %Normandy.MCP.ToolWrapper{tool: %{name: String.duplicate("a", 65)}}

      assert_raise ArgumentError, ~r/is not a valid tool name/, fn ->
        Toolset.register(Toolset.new(), too_long)
      end
    end

    test "a 64-character name with dashes and underscores is accepted" do
      name = "a-b_" <> String.duplicate("c", 60)
      tool = %Normandy.MCP.ToolWrapper{tool: %{name: name}}

      assert Toolset.has_tool?(Toolset.register(Toolset.new(), tool), name)
    end
  end

  describe "Toolset.fetch/2" do
    test "returns the registered tool" do
      tool = %Calculator{}
      toolset = Toolset.new([tool])

      assert {:ok, ^tool} = Toolset.fetch(toolset, "calculator")
    end

    test "returns :error for a name that is not registered" do
      assert :error = Toolset.fetch(Toolset.new(), "nonexistent")
    end
  end

  describe "Toolset.fetch!/2" do
    test "returns the registered tool" do
      tool = %Calculator{}
      assert ^tool = Toolset.fetch!(Toolset.new([tool]), "calculator")
    end

    test "raises ToolNotFoundError naming the tool and the registered names" do
      toolset = Toolset.new([%StringManipulator{}, %Calculator{}])

      error =
        assert_raise Normandy.ToolNotFoundError, fn -> Toolset.fetch!(toolset, "nope") end

      assert error.name == "nope"
      assert error.registered == ["calculator", "string_manipulator"]

      assert Exception.message(error) ==
               ~s(no tool named "nope" in the toolset; registered: "calculator", "string_manipulator")
    end

    test "says so when the toolset is empty" do
      error =
        assert_raise Normandy.ToolNotFoundError, fn -> Toolset.fetch!(Toolset.new(), "nope") end

      assert Exception.message(error) == ~s(no tool named "nope" in the toolset; it has no tools)
    end
  end

  describe "registration options" do
    test "new/1 takes {tool, opts} entries beside bare tools" do
      toolset = Toolset.new([{%Calculator{}, []}, %StringManipulator{}])

      assert Enum.sort(Toolset.list_names(toolset)) == ["calculator", "string_manipulator"]
    end

    test "new/1 passes an entry's options to register/3" do
      toolset = Toolset.new([%Calculator{}, {%Calculator{}, replace: true}])
      assert Toolset.count(toolset) == 1
    end

    test "an unknown option raises, naming the function and the key" do
      error =
        assert_raise ArgumentError, fn ->
          Toolset.register(Toolset.new(), %Calculator{}, replase: true)
        end

      assert String.starts_with?(error.message, "Normandy.Tools.Toolset.register/3: ")
      assert error.message =~ ":replase"
    end

    test "a wrongly typed option raises, naming the key" do
      error =
        assert_raise ArgumentError, fn ->
          Toolset.register(Toolset.new(), %Calculator{}, replace: "yes")
        end

      assert String.starts_with?(error.message, "Normandy.Tools.Toolset.register/3: ")
      assert error.message =~ ":replace"
    end
  end

  describe "Toolset.unregister/2" do
    test "removes tool from registry" do
      tool = %Calculator{operation: "add", a: 1, b: 2}
      registry = Toolset.new([tool])

      assert Toolset.count(registry) == 1

      registry = Toolset.unregister(registry, "calculator")

      assert Toolset.count(registry) == 0
      assert :error = Toolset.fetch(registry, "calculator")
    end

    test "does nothing if tool doesn't exist" do
      registry = Toolset.new()
      registry = Toolset.unregister(registry, "nonexistent")
      assert Toolset.count(registry) == 0
    end
  end

  describe "Toolset.list/1" do
    test "returns all registered tools" do
      tool1 = %Calculator{operation: "add", a: 1, b: 2}
      tool2 = %StringManipulator{operation: "uppercase", text: "hello"}

      registry = Toolset.new([tool1, tool2])
      tools = Toolset.list(registry)

      assert length(tools) == 2
      assert tool1 in tools
      assert tool2 in tools
    end

    test "returns empty list for empty registry" do
      registry = Toolset.new()
      assert [] = Toolset.list(registry)
    end
  end

  describe "Toolset.list_names/1" do
    test "returns all tool names" do
      tools = [
        %Calculator{operation: "add", a: 0, b: 0},
        %StringManipulator{operation: "uppercase", text: ""},
        %ListProcessor{operation: "sum", numbers: []}
      ]

      registry = Toolset.new(tools)
      names = Toolset.list_names(registry)

      assert length(names) == 3
      assert "calculator" in names
      assert "string_manipulator" in names
      assert "list_processor" in names
    end
  end

  describe "Toolset.has_tool?/2" do
    test "returns true for registered tool" do
      tool = %Calculator{operation: "add", a: 1, b: 2}
      registry = Toolset.new([tool])

      assert Toolset.has_tool?(registry, "calculator") == true
    end

    test "returns false for unregistered tool" do
      registry = Toolset.new()
      assert Toolset.has_tool?(registry, "calculator") == false
    end
  end

  describe "Toolset.to_tool_schemas/1" do
    test "generates tool schemas for LLM" do
      tool = %Calculator{operation: "add", a: 1, b: 2}
      registry = Toolset.new([tool])

      schemas = Toolset.to_tool_schemas(registry)

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

      registry = Toolset.new(tools)
      schemas = Toolset.to_tool_schemas(registry)

      assert length(schemas) == 2
      names = Enum.map(schemas, & &1.name)
      assert "calculator" in names
      assert "string_manipulator" in names
    end
  end
end
