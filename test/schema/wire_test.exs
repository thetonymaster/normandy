defmodule Normandy.Schema.WireTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.RetryFeedback
  alias Normandy.LLM.Json.SchemaTranslator
  alias Normandy.Schema.Wire
  alias Normandy.Tools.Toolset

  # Field names the VM already knows, declared out of both alphabetical and atom-table
  # order: before AX-17 these came out as error, id, name, type, value.
  defmodule Ordered do
    use Normandy.Schema

    io_schema "An answer in declaration order" do
      field(:value, :string, description: "The answer", required: true)
      field(:type, :string)
      field(:name, :string, description: "Who asked")
      field(:id, :integer)
      field(:error, :boolean)
      field(:title, :string, description: "A property named title is kept")
    end
  end

  defmodule Outer do
    use Normandy.Schema

    io_schema "Nests Ordered" do
      field(:zeta, :string, description: "first")
      field(:inner, Ordered, description: "second")
      field(:many, {:array, Ordered}, description: "third")
    end
  end

  defmodule OrderedTool do
    use Normandy.Tool,
      name: "ordered_tool",
      description: "Takes ordered input",
      input: Normandy.Schema.WireTest.Ordered

    defstruct []

    @impl Normandy.Tool
    def run(_tool, _context), do: {:ok, "ok"}
  end

  @order ["value", "type", "name", "id", "error", "title"]

  defp decode(json), do: Jason.decode!(json, objects: :ordered_objects)
  defp keys(%Jason.OrderedObject{values: values}), do: Enum.map(values, &elem(&1, 0))

  # Every node of a decoded schema, for whole-tree assertions.
  defp nodes(%Jason.OrderedObject{values: values} = node),
    do: [node | Enum.flat_map(values, fn {_k, v} -> nodes(v) end)]

  defp nodes(list) when is_list(list), do: Enum.flat_map(list, &nodes/1)
  defp nodes(_leaf), do: []

  test "properties are sent in declaration order" do
    encoded = Ordered.__schema__(:specification) |> Wire.encodable() |> Normandy.JSON.encode!()

    assert keys(decode(encoded)["properties"]) == @order
  end

  test "nested and array-item schemas keep their own order" do
    schema = Outer.__schema__(:specification) |> Wire.encodable() |> Normandy.JSON.encode!()
    decoded = decode(schema)

    assert keys(decoded["properties"]) == ["zeta", "inner", "many"]
    assert keys(decoded["properties"]["inner"]["properties"]) == @order
    assert keys(decoded["properties"]["many"]["items"]["properties"]) == @order
  end

  test "$schema, title and :property_order are not sent; a property named title is" do
    decoded =
      Ordered.__schema__(:specification)
      |> Wire.encodable()
      |> Normandy.JSON.encode!()
      |> decode()

    refute "$schema" in keys(decoded)
    refute "title" in keys(decoded)
    refute "property_order" in keys(decoded)
    assert decoded["properties"]["title"]["description"] == "A property named title is kept"
  end

  test "an undescribed field has no description, never \"\" or null (AX-11)" do
    decoded =
      Outer.__schema__(:specification) |> Wire.encodable() |> Normandy.JSON.encode!() |> decode()

    for %Jason.OrderedObject{} = node <- nodes(decoded), {"description", value} <- node.values do
      assert is_binary(value) and value != "", "empty description in #{inspect(node)}"
    end

    refute Map.has_key?(Ordered.__schema__(:specification).properties.type, :description)
  end

  test "a schema without :property_order passes through with its properties as a map" do
    hand_written = %{
      "type" => "object",
      "title" => "Lookup",
      "properties" => %{"query" => %{"type" => "string", "title" => "Query"}}
    }

    assert Wire.encodable(hand_written) == %{
             "type" => "object",
             "properties" => %{"query" => %{"type" => "string"}}
           }

    assert Wire.encodable(nil) == nil
  end

  test "title is removed inside every schema-valued keyword, atom or string keyed" do
    for k <- [& &1, &String.to_atom/1] do
      leaf = %{k.("type") => "string", k.("title") => "Leaf"}
      stripped = %{k.("type") => "string"}

      keywords = %{
        k.("$defs") => {%{"a" => leaf}, %{"a" => stripped}},
        k.("definitions") => {%{"b" => leaf}, %{"b" => stripped}},
        k.("patternProperties") => {%{"^x_" => leaf}, %{"^x_" => stripped}},
        k.("dependentSchemas") =>
          {%{"c" => %{k.("properties") => %{"d" => leaf}}},
           %{"c" => %{k.("properties") => %{"d" => stripped}}}},
        k.("contains") => {leaf, stripped},
        k.("propertyNames") => {leaf, stripped},
        k.("unevaluatedProperties") => {leaf, stripped},
        k.("unevaluatedItems") => {leaf, stripped}
      }

      spec = Map.new(keywords, fn {key, {sent, _}} -> {key, sent} end)
      expected = Map.new(keywords, fn {key, {_, out}} -> {key, out} end)

      assert Wire.encodable(Map.put(spec, k.("title"), "Root")) == expected
    end
  end

  test "a :property_order that does not name the properties raises, naming both" do
    spec = %{type: :object, properties: %{a: %{type: :string}}, property_order: [:a, :b]}

    assert_raise ArgumentError,
                 "expected :property_order to name each property exactly once, got " <>
                   "[:a, :b] for the properties [:a]",
                 fn -> Wire.encodable(spec) end
  end

  describe "every model-facing boundary sends declaration order" do
    test "tool input_schema (Toolset.to_tool_schemas/1)" do
      [%{input_schema: input_schema}] = Toolset.to_tool_schemas(Toolset.new([%OrderedTool{}]))

      assert keys(decode(Normandy.JSON.encode!(input_schema))["properties"]) == @order
    end

    test "the JSON retry feedback" do
      feedback =
        RetryFeedback.build(
          {:json_parse_error, :invalid, "oops"},
          "oops",
          %Ordered{}
        )

      [_, json] = Regex.run(~r/## Required Schema\n```json\n(.*)\n```/s, feedback)
      assert keys(decode(json)["properties"]) == @order
    end

    test "the structured-outputs schema (SchemaTranslator)" do
      {:ok, schema} = SchemaTranslator.translate(Ordered.__schema__(:specification))

      assert keys(decode(Jason.encode!(schema))["properties"]) == @order
      assert schema["required"] == ["value"]
    end
  end
end
