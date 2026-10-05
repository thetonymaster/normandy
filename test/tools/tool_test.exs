defmodule Normandy.ToolTest do
  use ExUnit.Case, async: true

  alias Normandy.Tool
  alias Normandy.Tools.Context

  defmodule Search do
    @moduledoc false
    defmodule Input do
      @moduledoc false
      use Normandy.Schema

      io_schema "Search input" do
        field(:query, :string, required: true, description: "What to look for")
        field(:limit, :integer, default: 5, minimum: 1)
      end
    end

    use Normandy.Tool, name: "search", description: "Searches the catalogue", input: Input

    defstruct index: "main"

    @impl Normandy.Tool
    def run(%__MODULE__{index: index}, %Context{input: %Input{query: query, limit: limit}}),
      do: {:ok, "#{index}:#{query}:#{limit}"}
  end

  defmodule HandWritten do
    @moduledoc false
    use Normandy.Tool

    defstruct prefix: "hw"

    @impl Normandy.Tool
    def name(%__MODULE__{prefix: prefix}), do: "#{prefix}_tool"

    @impl Normandy.Tool
    def description(_tool), do: "hand-written"

    @impl Normandy.Tool
    def input_schema(_tool),
      do: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}

    @impl Normandy.Tool
    def run(_tool, %Context{input: input}), do: {:ok, input}
  end

  describe "use Normandy.Tool" do
    test "generates name/1, description/1 and input_schema/1 from its options" do
      assert Search.name(%Search{}) == "search"
      assert Search.description(%Search{}) == "Searches the catalogue"
      assert Search.input_schema(%Search{}) == Search.Input.__schema__(:specification)
      assert Search.__tool_input__() == Search.Input
    end

    test "without options the module writes the callbacks; no input module is declared" do
      assert HandWritten.name(%HandWritten{prefix: "x"}) == "x_tool"
      refute function_exported?(HandWritten, :__tool_input__, 0)
    end

    test "declares the behaviour" do
      assert Tool.implemented_by?(Search)
      assert Tool.implemented_by?(HandWritten)
      refute Tool.implemented_by?(Normandy.Tools.Context)
      refute Tool.implemented_by?(:not_a_module)
    end
  end

  describe "the dispatching functions" do
    test "call the tool module's callbacks" do
      tool = %Search{index: "books"}

      assert Tool.name(tool) == "search"
      assert Tool.description(tool) == "Searches the catalogue"
      assert Tool.input_schema(tool) == Search.Input.__schema__(:specification)

      context = %Context{tool_call_id: "c1", input: %Search.Input{query: "dune", limit: 2}}
      assert Tool.run(tool, context) == {:ok, "books:dune:2"}
    end
  end

  describe "options are checked when the tool compiles" do
    test "an unknown option names the module and the key" do
      error =
        assert_raise ArgumentError, fn ->
          Code.compile_string("""
          defmodule Normandy.ToolTest.UnknownOption do
            use Normandy.Tool, nam: "x"
          end
          """)
        end

      assert error.message ==
               "use Normandy.Tool in Normandy.ToolTest.UnknownOption: unknown option :nam; " <>
                 "supported: :name, :description, :input"
    end

    test "a name the API would reject" do
      error =
        assert_raise ArgumentError, fn ->
          Code.compile_string("""
          defmodule Normandy.ToolTest.BadName do
            use Normandy.Tool, name: "has space"
          end
          """)
        end

      assert error.message ==
               "use Normandy.Tool in Normandy.ToolTest.BadName: :name must be 1 to 64 letters, " <>
                 ~s(digits, underscores or dashes, got: "has space")
    end

    test "an input module that is not a Normandy.Schema" do
      error =
        assert_raise ArgumentError, fn ->
          Code.compile_string("""
          defmodule Normandy.ToolTest.BadInput do
            use Normandy.Tool, input: Normandy.Tools.Context
          end
          """)
        end

      assert error.message ==
               "use Normandy.Tool in Normandy.ToolTest.BadInput: :input must be a module that " <>
                 "uses Normandy.Schema, got: Normandy.Tools.Context"
    end
  end

  test "a new context's :input defaults to nil" do
    assert %Context{tool_call_id: "c"}.input == nil
  end
end
