defmodule NormandyTest.Tools.ToolsetTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.Examples.{Calculator, ListProcessor, StringManipulator}
  alias Normandy.Tools.Toolset

  describe "Toolset.new/0" do
    test "creates an empty toolset" do
      registry = Toolset.new()
      assert %Toolset{tools: tools} = registry
      assert tools == %{}
      assert Toolset.count(registry) == 0
    end
  end

  describe "Toolset.register_new/3" do
    defmodule BadName do
      @behaviour Normandy.Tool
      defstruct []

      @impl true
      def name(_tool), do: "bad name"
      @impl true
      def description(_tool), do: "d"
      @impl true
      def input_schema(_tool), do: nil
      @impl true
      def run(_tool, _context), do: {:ok, "x"}
    end

    test "registers a new valid name" do
      assert {:ok, registry} = Toolset.register_new(Toolset.new(), %Calculator{}, timeout: 5_000)
      assert Toolset.timeout(registry, "calculator") == 5_000
    end

    test "a taken name is an error, not a replace" do
      registry = Toolset.new([%Calculator{}])

      assert {:error, {:tool_name_taken, "calculator"}} =
               Toolset.register_new(registry, %Calculator{})
    end

    test "a name the API would refuse is an error" do
      assert {:error, {:invalid_tool_name, "bad name"}} =
               Toolset.register_new(Toolset.new(), struct(BadName))
    end
  end

  describe "Toolset.new/1" do
    test "creates a toolset with tools" do
      tools = [
        %Calculator{},
        %StringManipulator{}
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
      tool = %Calculator{}

      registry = Toolset.register(registry, tool)

      assert Toolset.count(registry) == 1
      assert {:ok, ^tool} = Toolset.fetch(registry, "calculator")
    end

    test "a second tool with the same name raises" do
      registry = Toolset.new([%Calculator{}])

      assert_raise ArgumentError, ~r/"calculator" is already registered/, fn ->
        Toolset.register(registry, %Calculator{})
      end
    end

    test "replace: true replaces the tool with the same name" do
      tool1 = %Calculator{}
      tool2 = %Normandy.Test.FakeTool{name: "calculator"}

      registry =
        Toolset.new()
        |> Toolset.register(tool1)
        |> Toolset.register(tool2, replace: true)

      assert Toolset.count(registry) == 1
      assert {:ok, ^tool2} = Toolset.fetch(registry, "calculator")
    end

    test "unregister/2 drops the timeout of the tool it drops" do
      toolset = Toolset.register(Toolset.new(), %Calculator{}, timeout: 1_000)

      assert Toolset.timeout(toolset, "calculator") == 1_000
      assert Toolset.timeout(Toolset.unregister(toolset, "calculator"), "calculator") == nil
    end

    test "a name the API would reject raises at registration" do
      dotted = %Normandy.MCP.ToolWrapper{
        adapter: nil,
        client: nil,
        tool: %{name: "web.search"},
        prefix: false
      }

      assert_raise ArgumentError, ~r/"web.search" is not a valid tool name/, fn ->
        Toolset.register(Toolset.new(), dotted)
      end

      too_long = %Normandy.MCP.ToolWrapper{
        adapter: nil,
        client: nil,
        tool: %{name: String.duplicate("a", 65)},
        prefix: false
      }

      assert_raise ArgumentError, ~r/is not a valid tool name/, fn ->
        Toolset.register(Toolset.new(), too_long)
      end
    end

    test "a 64-character name with dashes and underscores is accepted" do
      name = "a-b_" <> String.duplicate("c", 60)

      tool = %Normandy.MCP.ToolWrapper{
        adapter: nil,
        client: nil,
        tool: %{name: name},
        prefix: false
      }

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

    test "max_result_chars: a cap, nil (no cap), or absent (the agent's cap)" do
      toolset =
        Toolset.new()
        |> Toolset.register(%Calculator{}, max_result_chars: 500)
        |> Toolset.register(%StringManipulator{}, max_result_chars: nil)
        |> Toolset.register(%ListProcessor{})

      assert Toolset.max_result_chars(toolset, "calculator") == {:ok, 500}
      assert Toolset.max_result_chars(toolset, "string_manipulator") == {:ok, nil}
      assert Toolset.max_result_chars(toolset, "list_processor") == :error
      assert Toolset.max_result_chars(toolset, "not_registered") == :error
    end

    test "re-registering without max_result_chars drops the old cap" do
      toolset =
        Toolset.new()
        |> Toolset.register(%Calculator{}, max_result_chars: 500)
        |> Toolset.register(%Calculator{}, replace: true)

      assert Toolset.max_result_chars(toolset, "calculator") == :error
    end

    test "unregister/2 drops the cap of the tool it drops" do
      toolset = Toolset.register(Toolset.new(), %Calculator{}, max_result_chars: 500)

      assert Toolset.max_result_chars(Toolset.unregister(toolset, "calculator"), "calculator") ==
               :error
    end

    test "a max_result_chars that is not a positive integer or nil raises, naming the key" do
      for bad <- [0, -1, 1.5] do
        error =
          assert_raise ArgumentError, fn ->
            Toolset.register(Toolset.new(), %Calculator{}, max_result_chars: bad)
          end

        assert String.starts_with?(error.message, "Normandy.Tools.Toolset.register/3: ")
        assert error.message =~ "invalid value for :max_result_chars option"
      end
    end
  end

  describe "Toolset.unregister/2" do
    test "removes a tool from the toolset" do
      tool = %Calculator{}
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
      tool1 = %Calculator{}
      tool2 = %StringManipulator{}

      registry = Toolset.new([tool1, tool2])
      tools = Toolset.list(registry)

      assert length(tools) == 2
      assert tool1 in tools
      assert tool2 in tools
    end

    test "returns an empty list for an empty toolset" do
      registry = Toolset.new()
      assert [] = Toolset.list(registry)
    end
  end

  describe "Toolset.list_names/1" do
    test "returns all tool names" do
      tools = [
        %Calculator{},
        %StringManipulator{},
        %ListProcessor{}
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
      tool = %Calculator{}
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
      tool = %Calculator{}
      registry = Toolset.new([tool])

      schemas = Toolset.to_tool_schemas(registry)

      assert length(schemas) == 1
      assert [schema] = schemas

      assert schema.name == "calculator"

      assert schema.description ==
               "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers"

      assert schema.input_schema.type == :object
      # Declaration order, through Normandy.Schema.Wire (AX-17).
      assert %Jason.OrderedObject{} = schema.input_schema.properties
      assert %{type: :string} = schema.input_schema.properties[:operation]
      refute Map.has_key?(schema.input_schema, :property_order)
    end

    test "generates multiple tool schemas" do
      tools = [
        %Calculator{},
        %StringManipulator{}
      ]

      registry = Toolset.new(tools)
      schemas = Toolset.to_tool_schemas(registry)

      assert length(schemas) == 2
      names = Enum.map(schemas, & &1.name)
      assert "calculator" in names
      assert "string_manipulator" in names
    end
  end

  describe "1.x tools (Ruling 5)" do
    defmodule OldStyleTool do
      @moduledoc false
      defstruct api_key: "secret-value"
    end

    test "a struct whose module does not implement Normandy.Tool raises, naming the module" do
      error =
        assert_raise ArgumentError, fn -> Toolset.register(Toolset.new(), %OldStyleTool{}) end

      assert error.message ==
               "Normandy.Tools.Toolset.register/3: NormandyTest.Tools.ToolsetTest.OldStyleTool " <>
                 "does not implement the Normandy.Tool behaviour. 1.x tools " <>
                 "(Normandy.Tools.BaseTool, SchemaBaseTool, ContextualTool) are replaced by it " <>
                 "in 2.0; see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour)"

      refute error.message =~ "secret-value"
    end

    test "something that is not a struct raises" do
      error = assert_raise ArgumentError, fn -> Toolset.new([%{name: "x"}]) end

      assert error.message ==
               "Normandy.Tools.Toolset.register/3: expected a tool struct whose module " <>
                 "implements Normandy.Tool, got: a map; " <>
                 "see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour)"
    end
  end
end
