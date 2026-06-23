defmodule Normandy.LLM.Json.SchemaTranslatorTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.SchemaTranslator

  test "translates a flat object: string keys, additionalProperties:false, required" do
    spec = %{
      type: :object,
      title: "Out",
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      properties: %{
        chat_message: %{type: :string, description: "msg", default: ""},
        count: %{type: :integer, description: ""}
      },
      required: [:chat_message]
    }

    assert {:ok, schema} = SchemaTranslator.translate(spec)

    assert schema == %{
             "type" => "object",
             "additionalProperties" => false,
             "required" => ["chat_message"],
             "properties" => %{
               "chat_message" => %{"type" => "string", "description" => "msg"},
               "count" => %{"type" => "integer"}
             }
           }
  end

  test "recurses additionalProperties:false into nested objects" do
    spec = %{
      type: :object,
      properties: %{
        addr: %{type: :object, properties: %{city: %{type: :string}}, required: [:city]}
      },
      required: [:addr]
    }

    assert {:ok, schema} = SchemaTranslator.translate(spec)
    assert schema["properties"]["addr"]["additionalProperties"] == false
    assert schema["properties"]["addr"]["required"] == ["city"]
  end

  test "translates arrays via items" do
    spec = %{
      type: :object,
      properties: %{tags: %{type: :array, items: %{type: :string}}},
      required: []
    }

    assert {:ok, schema} = SchemaTranslator.translate(spec)
    assert schema["properties"]["tags"] == %{"type" => "array", "items" => %{"type" => "string"}}
  end

  test "strips unsupported keywords (title/$schema/default/min_length)" do
    spec = %{
      type: :object,
      "$schema": "x",
      properties: %{name: %{type: :string, min_length: 3, default: "z"}},
      required: [:name]
    }

    assert {:ok, schema} = SchemaTranslator.translate(spec)
    refute Map.has_key?(schema, "$schema")
    refute Map.has_key?(schema["properties"]["name"], "min_length")
    refute Map.has_key?(schema["properties"]["name"], "default")
  end

  test "open object (no properties — a Normandy :map field) is incompatible" do
    spec = %{type: :object, properties: %{meta: %{type: :object, default: nil}}, required: []}
    assert {:incompatible, {:open_object, _}} = SchemaTranslator.translate(spec)
  end

  test "runaway nesting depth is incompatible" do
    deep =
      Enum.reduce(1..12, %{type: :string}, fn _, acc ->
        %{type: :object, properties: %{n: acc}, required: [:n]}
      end)

    assert {:incompatible, :too_deep} = SchemaTranslator.translate(deep)
  end

  test "allowlisted scalar :number (a float field) translates to a JSON Schema number" do
    spec = %{type: :object, properties: %{price: %{type: :number}}, required: [:price]}
    assert {:ok, schema} = SchemaTranslator.translate(spec)
    assert schema["properties"]["price"] == %{"type" => "number"}
  end

  test "an unsupported scalar type (:map) is incompatible" do
    spec = %{type: :object, properties: %{meta: %{type: :map}}, required: [:meta]}
    assert {:incompatible, {:unsupported_type, :map}} = SchemaTranslator.translate(spec)
  end

  test "an unsupported scalar type (:date) is incompatible" do
    spec = %{type: :object, properties: %{when: %{type: :date}}, required: [:when]}
    assert {:incompatible, {:unsupported_type, :date}} = SchemaTranslator.translate(spec)
  end

  test "a :float-typed node translates to a JSON Schema number" do
    spec = %{type: :object, properties: %{ratio: %{type: :float}}, required: [:ratio]}
    assert {:ok, schema} = SchemaTranslator.translate(spec)
    assert schema["properties"]["ratio"] == %{"type" => "number"}
  end
end
