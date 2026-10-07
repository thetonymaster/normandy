defmodule Normandy.Tools.InputTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.{Context, Input}

  doctest Input

  # The SEC-1 shape: configuration on the struct, the model's input in a separate schema.
  defmodule EndpointTool do
    @moduledoc false
    defmodule Params do
      @moduledoc false
      use Normandy.Schema

      io_schema "Lookup input" do
        field(:query, :string, required: true, description: "the query")
        field(:limit, :integer, default: 5)
      end
    end

    use Normandy.Tool, name: "lookup", description: "looks a query up", input: Params

    defstruct [:endpoint, timeout: 5_000]

    @impl Normandy.Tool
    def run(_tool, %Context{input: input}), do: {:ok, input}
  end

  defmodule MapTool do
    @moduledoc false
    use Normandy.Tool, name: "map_tool", description: "hand-written schema"

    defstruct additional: false

    # Atom and string keys mixed on purpose: built-in tools use both.
    @impl Normandy.Tool
    def input_schema(%__MODULE__{additional: additional}) do
      %{
        :type => "object",
        "properties" => %{"n" => %{"type" => "integer"}, name: %{type: "string"}},
        :required => ["n"],
        "additionalProperties" => additional
      }
    end

    @impl Normandy.Tool
    def run(_tool, %Context{input: input}), do: {:ok, input}
  end

  # Any hand-written schema, as given (an MCP server's, for instance).
  defmodule SchemaTool do
    @moduledoc false
    use Normandy.Tool, name: "schema_tool", description: "the schema it is given"

    defstruct schema: %{"type" => "object"}

    @impl Normandy.Tool
    def input_schema(%__MODULE__{schema: schema}), do: schema

    @impl Normandy.Tool
    def run(_tool, %Context{input: input}), do: {:ok, input}
  end

  alias EndpointTool.Params

  describe "a tool that declared input: Schema" do
    test "string keys become the schema's struct, with defaults" do
      assert {:ok, %Params{query: "x", limit: 5}} =
               Input.validate(%EndpointTool{}, %{"query" => "x"})
    end

    test "atom keys are accepted" do
      assert {:ok, %Params{query: "x", limit: 2}} =
               Input.validate(%EndpointTool{}, %{query: "x", limit: 2})
    end

    test "keys that name the tool's config fields are unknown keys, named in the error" do
      input = %{"query" => "x", "endpoint" => "evil", "timeout" => "x"}

      assert {:error, [error]} = Input.validate(%EndpointTool{}, input)

      assert error == %{
               path: [],
               constraint: :unknown_keys,
               message: ~s(unknown keys "endpoint", "timeout"; expected only "query", "limit")
             }

      assert Input.message([error]) ==
               ~s(unknown keys "endpoint", "timeout"; expected only "query", "limit")
    end

    test "one unknown key is named in the singular" do
      assert {:error, [%{message: ~s(unknown key "x"; expected only "query", "limit")}]} =
               Input.validate(%EndpointTool{}, %{"query" => "q", "x" => 1})
    end

    test "a missing required field and a wrong type, without coercion" do
      assert {:error, errors} = Input.validate(%EndpointTool{}, %{"limit" => "5"})

      assert errors == [
               %{path: [:limit], message: "expected type integer, got string", constraint: :type},
               %{path: [:query], message: "is required", constraint: :required}
             ]

      assert Input.message(errors) == "limit expected type integer, got string; query is required"
    end

    test "a key given both as a string and as an atom is an error, not a silent pick" do
      assert {:error, [%{path: ["query"], constraint: :duplicate_key}]} =
               Input.validate(%EndpointTool{}, %{"query" => "a", query: "b"})
    end

    test "an unknown key is never turned into an atom" do
      canary = "input_canary_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(canary) end

      assert {:error, _} = Input.validate(%EndpointTool{}, %{"query" => "q", canary => 1})

      assert_raise ArgumentError, fn -> String.to_existing_atom(canary) end
    end
  end

  describe "a tool with a hand-written input_schema/1 map" do
    test "valid input comes back as a string-keyed map" do
      assert {:ok, %{"n" => 1, "name" => "a"}} =
               Input.validate(%MapTool{}, %{"n" => 1, name: "a"})
    end

    test "unknown keys, missing required keys and basic types" do
      assert {:error, errors} = Input.validate(%MapTool{}, %{"name" => 3, "extra" => true})

      assert errors == [
               %{
                 path: [],
                 message: ~s(unknown key "extra"; expected only "n", "name"),
                 constraint: :unknown_keys
               },
               %{path: ["n"], message: "is required", constraint: :required},
               %{path: ["name"], message: "expected type string, got integer", constraint: :type}
             ]
    end

    test "additionalProperties true lets other keys through" do
      assert {:ok, %{"n" => 1, "extra" => true}} =
               Input.validate(%MapTool{additional: true}, %{"n" => 1, "extra" => true})
    end

    # Decision 18: an MCP server may publish a loose schema with no `properties`.
    test "a schema with no properties key accepts any keys" do
      assert {:ok, %{"anything" => 1}} = Input.validate(%SchemaTool{}, %{"anything" => 1})
    end

    test "a schema with no properties key still checks its required keys" do
      tool = %SchemaTool{schema: %{"type" => "object", "required" => ["q"]}}

      assert {:error, [%{path: ["q"], message: "is required", constraint: :required}]} =
               Input.validate(tool, %{"anything" => 1})
    end

    test "properties without additionalProperties reject an unknown key, naming it" do
      tool = %SchemaTool{schema: %{"type" => "object", "properties" => %{"q" => %{}}}}

      assert {:error, [error]} = Input.validate(tool, %{"q" => "x", "extra" => 1})

      assert error == %{
               path: [],
               message: ~s(unknown key "extra"; expected only "q"),
               constraint: :unknown_keys
             }
    end

    test "a schema with no properties key still wants an object" do
      assert {:error, [%{path: [], constraint: :type}]} = Input.validate(%SchemaTool{}, [1])
    end

    # An MCP tool whose server sent no schema has input_schema nil (Claudio's
    # %MCP.Client.Tool{} default): an error result for the model, not a crash in the turn.
    test "an input_schema/1 that is not a map is an error, not a crash" do
      assert {:error, [%{path: [], constraint: :schema, message: message}]} =
               Input.validate(%SchemaTool{schema: nil}, %{"q" => 1})

      assert message == "the tool's input_schema/1 returned nil, not a JSON Schema map"
    end

    # 3.4b-M1: a malformed hand-written schema (an MCP server's) is an error result, not a
    # Protocol.UndefinedError in the turn.
    test "properties that is not a map is a schema error, not a crash" do
      tool = %SchemaTool{schema: %{"type" => "object", "properties" => nil}}

      assert {:error, [%{path: [], constraint: :schema, message: message}]} =
               Input.validate(tool, %{"q" => 1})

      assert message == ~s(the tool's input_schema/1 "properties" is nil, not a map)
    end

    test "required that is not a list of key names is a schema error, not a crash" do
      for {required, got} <- [{"q", "a string (1 bytes)"}, {[%{}], "a list"}] do
        tool = %SchemaTool{schema: %{"type" => "object", "required" => required}}

        assert {:error, [%{path: [], constraint: :schema, message: message}]} =
                 Input.validate(tool, %{"q" => 1})

        assert message ==
                 ~s(the tool's input_schema/1 "required" is #{got}, not a list of key names)
      end
    end

    test "a key that is neither a string nor an atom is named by its type and refused" do
      for schema <- [%{"type" => "object"}, %{"type" => "object", "properties" => %{"q" => %{}}}] do
        assert {:error, [error]} = Input.validate(%SchemaTool{schema: schema}, %{{:a, 1} => 1})
        assert error.constraint == :unknown_keys
        assert error.message =~ ~s(unknown key "a tuple key")
        refute error.message =~ ":a"
      end
    end
  end

  test "a key that is neither a string nor an atom is an unknown key for a declared schema" do
    assert {:error, [%{constraint: :unknown_keys, message: message}]} =
             Input.validate(%EndpointTool{}, %{"query" => "x", 7 => 1})

    assert message == ~s(unknown key "an integer key"; expected only "query", "limit")
  end

  test "input that is not an object is a type error" do
    assert {:error,
            [%{path: [], constraint: :type, message: "expected a JSON object, got: a list"}]} =
             Input.validate(%EndpointTool{}, [1, 2])
  end
end
