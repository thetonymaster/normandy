defmodule NormandyTest.SchemaCompositionTest do
  use ExUnit.Case, async: true

  describe "anyOf composition" do
    defmodule AnyOfInline do
      use Normandy.Schema

      schema do
        field(:value, :any,
          description: "String or number",
          any_of: [
            %{type: :string, minLength: 1},
            %{type: :number, minimum: 0}
          ]
        )
      end
    end

    test "generates anyOf in JSON Schema with inline specs" do
      spec = AnyOfInline.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:anyOf]
      assert length(value_spec[:anyOf]) == 2
      assert %{type: :string, minLength: 1} in value_spec[:anyOf]
      assert %{type: :number, minimum: 0} in value_spec[:anyOf]
    end

    test "description is preserved with anyOf" do
      spec = AnyOfInline.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:description] == "String or number"
    end

    defmodule EmailSchema do
      use Normandy.Schema

      schema do
        field(:email, :string, required: true)
        field(:verified, :boolean, default: false)
      end
    end

    defmodule PhoneSchema do
      use Normandy.Schema

      schema do
        field(:phone, :string, required: true)
        field(:country_code, :string, default: "+1")
      end
    end

    defmodule AnyOfSchemas do
      use Normandy.Schema

      schema do
        field(:contact, :map,
          description: "Email or phone contact",
          any_of: [EmailSchema, PhoneSchema]
        )
      end
    end

    test "generates anyOf with schema modules" do
      spec = AnyOfSchemas.__schema__(:specification)
      contact_spec = spec.properties[:contact]

      assert contact_spec[:anyOf]
      assert length(contact_spec[:anyOf]) == 2

      email_schema = Enum.at(contact_spec[:anyOf], 0)
      assert email_schema[:type] == :object
      assert email_schema[:properties][:email]
      assert :email in email_schema[:required]

      phone_schema = Enum.at(contact_spec[:anyOf], 1)
      assert phone_schema[:type] == :object
      assert phone_schema[:properties][:phone]
      assert :phone in phone_schema[:required]
    end
  end

  describe "oneOf composition" do
    defmodule OneOfInline do
      use Normandy.Schema

      schema do
        field(:id, :any,
          description: "UUID or numeric ID",
          one_of: [
            %{type: :string, format: "uuid"},
            %{type: :integer, minimum: 1}
          ]
        )
      end
    end

    test "generates oneOf in JSON Schema" do
      spec = OneOfInline.__schema__(:specification)
      id_spec = spec.properties[:id]

      assert id_spec[:oneOf]
      assert length(id_spec[:oneOf]) == 2
      assert %{type: :string, format: "uuid"} in id_spec[:oneOf]
      assert %{type: :integer, minimum: 1} in id_spec[:oneOf]
    end

    defmodule CreditCardPayment do
      use Normandy.Schema

      schema do
        field(:card_number, :string, required: true)
        field(:cvv, :string, required: true)
      end
    end

    defmodule BankTransferPayment do
      use Normandy.Schema

      schema do
        field(:account_number, :string, required: true)
        field(:routing_number, :string, required: true)
      end
    end

    defmodule PayPalPayment do
      use Normandy.Schema

      schema do
        field(:paypal_email, :string, required: true)
      end
    end

    defmodule Payment do
      use Normandy.Schema

      schema do
        field(:method, :map,
          description: "Payment method details",
          one_of: [CreditCardPayment, BankTransferPayment, PayPalPayment]
        )
      end
    end

    test "generates oneOf with multiple schema modules" do
      spec = Payment.__schema__(:specification)
      method_spec = spec.properties[:method]

      assert method_spec[:oneOf]
      assert length(method_spec[:oneOf]) == 3

      schemas = method_spec[:oneOf]
      assert Enum.all?(schemas, fn schema -> schema[:type] == :object end)
      assert Enum.any?(schemas, fn schema -> Map.has_key?(schema[:properties], :card_number) end)

      assert Enum.any?(schemas, fn schema ->
               Map.has_key?(schema[:properties], :account_number)
             end)

      assert Enum.any?(schemas, fn schema -> Map.has_key?(schema[:properties], :paypal_email) end)
    end
  end

  describe "allOf composition" do
    defmodule BaseEntity do
      use Normandy.Schema

      schema do
        field(:id, :string, required: true)
        field(:created_at, :string, required: true)
      end
    end

    defmodule Timestamped do
      use Normandy.Schema

      schema do
        field(:updated_at, :string)
        field(:deleted_at, :string)
      end
    end

    defmodule AllOfSchemas do
      use Normandy.Schema

      schema do
        field(:entity, :map,
          description: "Entity with timestamps",
          all_of: [BaseEntity, Timestamped]
        )
      end
    end

    test "generates allOf with schema modules" do
      spec = AllOfSchemas.__schema__(:specification)
      entity_spec = spec.properties[:entity]

      assert entity_spec[:allOf]
      assert length(entity_spec[:allOf]) == 2

      schemas = entity_spec[:allOf]
      assert Enum.any?(schemas, fn schema -> Map.has_key?(schema[:properties], :id) end)
      assert Enum.any?(schemas, fn schema -> Map.has_key?(schema[:properties], :updated_at) end)
    end

    defmodule AllOfInline do
      use Normandy.Schema

      schema do
        field(:constrained_string, :string,
          description: "String with multiple constraints",
          all_of: [
            %{minLength: 5},
            %{maxLength: 100},
            %{pattern: "^[a-zA-Z]"}
          ]
        )
      end
    end

    test "generates allOf with inline constraint specs" do
      spec = AllOfInline.__schema__(:specification)
      string_spec = spec.properties[:constrained_string]

      assert string_spec[:allOf]
      assert length(string_spec[:allOf]) == 3
      assert %{minLength: 5} in string_spec[:allOf]
      assert %{maxLength: 100} in string_spec[:allOf]
      assert %{pattern: "^[a-zA-Z]"} in string_spec[:allOf]
    end
  end

  describe "mixed composition" do
    defmodule StringType do
      use Normandy.Schema

      schema do
        field(:value, :string, required: true)
      end
    end

    defmodule NumberType do
      use Normandy.Schema

      schema do
        field(:value, :integer, required: true)
      end
    end

    defmodule MixedComposition do
      use Normandy.Schema

      schema do
        # Using both inline specs and schema modules
        field(:flexible_value, :any,
          one_of: [
            StringType,
            %{type: :number, minimum: 0},
            %{type: :boolean}
          ]
        )
      end
    end

    test "supports mixing schema modules and inline specs" do
      spec = MixedComposition.__schema__(:specification)
      value_spec = spec.properties[:flexible_value]

      assert value_spec[:oneOf]
      assert length(value_spec[:oneOf]) == 3

      # First should be the schema module (object type)
      first = Enum.at(value_spec[:oneOf], 0)
      assert first[:type] == :object

      # Second and third should be inline specs
      inline_specs = Enum.slice(value_spec[:oneOf], 1, 2)
      assert %{type: :number, minimum: 0} in inline_specs
      assert %{type: :boolean} in inline_specs
    end
  end

  describe "composition with other constraints" do
    defmodule CompositionWithConstraints do
      use Normandy.Schema

      schema do
        field(:tagged_value, :any,
          description: "Value with type tag",
          required: true,
          one_of: [
            %{type: :string},
            %{type: :number}
          ],
          examples: ["hello", 42]
        )
      end
    end

    test "combines composition with other field options" do
      spec = CompositionWithConstraints.__schema__(:specification)
      value_spec = spec.properties[:tagged_value]

      # Has composition
      assert value_spec[:oneOf]
      assert length(value_spec[:oneOf]) == 2

      # Has other constraints
      assert value_spec[:description] == "Value with type tag"
      assert value_spec[:examples] == ["hello", 42]

      # Required is in schema level
      assert :tagged_value in spec.required
    end
  end

  describe "nested composition" do
    defmodule Inner1 do
      use Normandy.Schema

      schema do
        field(:type, :string, enum: ["type1"])
        field(:value1, :string)
      end
    end

    defmodule Inner2 do
      use Normandy.Schema

      schema do
        field(:type, :string, enum: ["type2"])
        field(:value2, :integer)
      end
    end

    defmodule Outer do
      use Normandy.Schema

      schema do
        field(:data, :map, one_of: [Inner1, Inner2])

        field(:metadata, :map,
          any_of: [
            %{type: :object},
            %{type: :array, items: %{type: :string}}
          ]
        )
      end
    end

    test "handles nested composition with multiple fields" do
      spec = Outer.__schema__(:specification)

      data_spec = spec.properties[:data]
      assert data_spec[:oneOf]
      assert length(data_spec[:oneOf]) == 2

      metadata_spec = spec.properties[:metadata]
      assert metadata_spec[:anyOf]
      assert length(metadata_spec[:anyOf]) == 2
    end
  end

  describe "io_schema with composition" do
    defmodule IOSchemaWithComposition do
      use Normandy.Schema

      io_schema "Input with flexible types" do
        field(:input_value, :any,
          description: "Flexible input value",
          required: true,
          any_of: [
            %{type: :string},
            %{type: :number},
            %{type: :boolean}
          ]
        )
      end
    end

    test "composition works with io_schema" do
      spec = IOSchemaWithComposition.__schema__(:specification)
      assert spec.description == "Input with flexible types"

      input_spec = spec.properties[:input_value]
      assert input_spec[:anyOf]
      assert length(input_spec[:anyOf]) == 3
    end
  end

  describe "empty composition lists" do
    test "empty anyOf list" do
      defmodule EmptyAnyOf do
        use Normandy.Schema

        schema do
          field(:value, :string, any_of: [])
        end
      end

      spec = EmptyAnyOf.__schema__(:specification)
      value_spec = spec.properties[:value]
      assert value_spec[:anyOf] == []
    end
  end

  describe "composition with array types" do
    defmodule ArrayComposition do
      use Normandy.Schema

      schema do
        field(:items, {:array, :any}, description: "Array of mixed types")
      end
    end

    test "array fields work alongside composition" do
      # Note: Composition is supported at field level, not at array item level
      spec = ArrayComposition.__schema__(:specification)
      items_spec = spec.properties[:items]

      assert items_spec[:type] == :array
      assert items_spec[:description] == "Array of mixed types"
    end
  end
end
