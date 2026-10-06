defmodule Normandy.LLM.Json.SchemaTranslatorTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.SchemaTranslator

  test "keeps the string formats structured outputs support, drops the others" do
    spec = %{
      type: :object,
      properties: %{
        on: %{type: :string, format: "date"},
        at: %{type: :string, format: "time"},
        lasts: %{type: :string, format: "duration"},
        mail: %{type: :string, format: "email"},
        blob: %{type: :string, format: "binary"}
      }
    }

    assert {:ok, %{"properties" => props}} = SchemaTranslator.translate(spec)
    assert props["on"] == %{"type" => "string", "format" => "date"}
    assert props["at"]["format"] == "time"
    assert props["lasts"]["format"] == "duration"
    assert props["mail"]["format"] == "email"
    # An unsupported format is stated, not sent (AX-18).
    assert props["blob"] == %{"type" => "string", "description" => "Format: binary."}
  end

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

  test "constraints constrained decoding cannot enforce are stated in the description (AX-18)" do
    spec = %{
      type: :object,
      properties: %{
        zip: %{
          type: :string,
          description: "Postal code",
          pattern: "^[0-9]{5}$",
          minLength: 5,
          maxLength: 5
        },
        qty: %{type: :integer, description: "How many.", minimum: 1, maximum: 100},
        price: %{type: :number, exclusiveMinimum: 0},
        tags: %{
          type: :array,
          items: %{type: :string},
          minItems: 1,
          maxItems: 3,
          uniqueItems: true
        },
        nick: %{type: :string, maxLength: 20}
      },
      required: []
    }

    assert {:ok, %{"properties" => props}} = SchemaTranslator.translate(spec)

    assert props["zip"] == %{
             "type" => "string",
             "description" =>
               "Postal code. Exactly 5 characters. Must match the regular expression ^[0-9]{5}$."
           }

    assert props["qty"]["description"] == "How many. Minimum 1. Maximum 100."
    assert props["price"]["description"] == "Greater than 0."
    assert props["tags"]["description"] == "Between 1 and 3 items. Items must be unique."
    assert props["nick"]["description"] == "At most 20 characters."
    refute Map.has_key?(props["zip"], "pattern")
  end

  defmodule Address do
    use Normandy.Schema

    io_schema "Address information" do
      field(:street, :string, description: "Street address", required: true)
      field(:city, :string, description: "City name", required: true)
      field(:state, :string, description: "State or province")
      field(:postal_code, :string, description: "Postal code", pattern: "^[0-9]{5}$")
    end
  end

  test "an io_schema's field order and constraints reach the constrained schema" do
    {:ok, schema} = SchemaTranslator.translate(Address.__schema__(:specification))

    assert Enum.map(schema["properties"], &elem(&1, 0)) == [
             "street",
             "city",
             "state",
             "postal_code"
           ]

    assert schema["properties"]["postal_code"]["description"] ==
             "Postal code. Must match the regular expression ^[0-9]{5}$."
  end
end
