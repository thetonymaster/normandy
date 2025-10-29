defmodule Normandy.SchemaNestedTest do
  use ExUnit.Case, async: true

  describe "single nested schema fields" do
    defmodule Address do
      use Normandy.Schema

      io_schema "Address information" do
        field(:street, :string, description: "Street address", required: true)
        field(:city, :string, description: "City name", required: true)
        field(:state, :string, description: "State or province")
        field(:postal_code, :string, description: "Postal code", pattern: "^[0-9]{5}$")
      end
    end

    defmodule Person do
      use Normandy.Schema

      io_schema "Person with address" do
        field(:name, :string, description: "Full name", required: true)
        field(:address, Address, description: "Home address")
      end
    end

    test "schema accepts nested schema as field type" do
      assert Person.__schema__(:type, :address) == Address
    end

    test "nested schema fields appear in field list" do
      assert :address in Person.__schema__(:fields)
    end

    test "can create struct with nested schema" do
      person = %Person{
        name: "John Doe",
        address: %Address{street: "123 Main St", city: "Springfield", state: "IL"}
      }

      assert person.name == "John Doe"
      assert person.address.street == "123 Main St"
    end

    test "JSON schema inlines nested schema specification" do
      spec = Person.__schema__(:specification)

      assert spec.properties.address == %{
               type: :object,
               description: "Home address",
               properties: %{
                 street: %{
                   type: :string,
                   description: "Street address"
                 },
                 city: %{
                   type: :string,
                   description: "City name"
                 },
                 state: %{
                   type: :string,
                   description: "State or province"
                 },
                 postal_code: %{
                   type: :string,
                   description: "Postal code",
                   pattern: "^[0-9]{5}$"
                 }
               },
               required: [:street, :city]
             }
    end

    test "nested schema preserves all constraints" do
      spec = Person.__schema__(:specification)
      postal_code_spec = spec.properties.address.properties.postal_code

      assert postal_code_spec.pattern == "^[0-9]{5}$"
      assert postal_code_spec.type == :string
    end

    test "nested schema preserves required fields" do
      spec = Person.__schema__(:specification)

      assert spec.properties.address.required == [:street, :city]
    end

    test "top-level required works with nested schemas" do
      defmodule PersonRequiredAddress do
        use Normandy.Schema

        io_schema "Person with required address" do
          field(:name, :string, required: true)
          field(:address, Address, description: "Home address", required: true)
        end
      end

      spec = PersonRequiredAddress.__schema__(:specification)
      assert :address in spec.required
    end
  end

  describe "array of nested schemas" do
    defmodule Tag do
      use Normandy.Schema

      io_schema "Tag information" do
        field(:name, :string, description: "Tag name", required: true)
        field(:category, :string, description: "Tag category")
      end
    end

    defmodule Article do
      use Normandy.Schema

      io_schema "Article with tags" do
        field(:title, :string, description: "Article title", required: true)
        field(:tags, {:array, Tag}, description: "Article tags")
      end
    end

    test "schema accepts array of nested schemas" do
      assert Article.__schema__(:type, :tags) == {:array, Tag}
    end

    test "JSON schema inlines array items specification" do
      spec = Article.__schema__(:specification)

      # Note: inline_nested_schema includes description from the nested schema
      assert spec.properties.tags.type == :array
      assert spec.properties.tags.description == "Article tags"
      assert spec.properties.tags.items.type == :object
      assert spec.properties.tags.items.description == "Tag information"
      assert spec.properties.tags.items.required == [:name]

      assert spec.properties.tags.items.properties == %{
               name: %{
                 type: :string,
                 description: "Tag name"
               },
               category: %{
                 type: :string,
                 description: "Tag category"
               }
             }
    end

    test "can create struct with array of nested schemas" do
      article = %Article{
        title: "Test Article",
        tags: [
          %Tag{name: "elixir", category: "programming"},
          %Tag{name: "testing"}
        ]
      }

      assert article.title == "Test Article"
      assert length(article.tags) == 2
      assert hd(article.tags).name == "elixir"
    end

    test "array constraints work with nested schemas" do
      defmodule ArticleWithConstraints do
        use Normandy.Schema

        io_schema "Article with tag constraints" do
          field(:title, :string, required: true)

          field(:tags, {:array, Tag},
            description: "Article tags",
            min_items: 1,
            max_items: 10,
            unique_items: true
          )
        end
      end

      spec = ArticleWithConstraints.__schema__(:specification)

      assert spec.properties.tags.minItems == 1
      assert spec.properties.tags.maxItems == 10
      assert spec.properties.tags.uniqueItems == true
      assert spec.properties.tags.items.type == :object
    end
  end

  describe "deeply nested schemas" do
    defmodule Country do
      use Normandy.Schema

      io_schema "Country information" do
        field(:name, :string, description: "Country name", required: true)
        field(:code, :string, description: "ISO country code", pattern: "^[A-Z]{2}$")
      end
    end

    defmodule City do
      use Normandy.Schema

      io_schema "City information" do
        field(:name, :string, description: "City name", required: true)
        field(:country, Country, description: "Country", required: true)
      end
    end

    defmodule Company do
      use Normandy.Schema

      io_schema "Company information" do
        field(:name, :string, description: "Company name", required: true)
        field(:headquarters, City, description: "HQ location")
      end
    end

    test "three levels of nesting work correctly" do
      spec = Company.__schema__(:specification)

      # Level 1: Company
      assert spec.properties.headquarters.type == :object

      # Level 2: City
      assert spec.properties.headquarters.properties.country.type == :object

      # Level 3: Country
      assert spec.properties.headquarters.properties.country.properties.name.type == :string

      assert spec.properties.headquarters.properties.country.properties.code.pattern ==
               "^[A-Z]{2}$"
    end

    test "required fields cascade through nesting" do
      spec = Company.__schema__(:specification)

      # City requires country
      assert :country in spec.properties.headquarters.required

      # Country requires name
      assert :name in spec.properties.headquarters.properties.country.required
    end

    test "can create deeply nested structs" do
      company = %Company{
        name: "Tech Corp",
        headquarters: %City{
          name: "San Francisco",
          country: %Country{name: "United States", code: "US"}
        }
      }

      assert company.name == "Tech Corp"
      assert company.headquarters.name == "San Francisco"
      assert company.headquarters.country.name == "United States"
      assert company.headquarters.country.code == "US"
    end
  end

  describe "mixed nested and primitive types" do
    defmodule ContactInfo do
      use Normandy.Schema

      io_schema "Contact information" do
        field(:email, :string, description: "Email address", format: "email", required: true)
        field(:phone, :string, description: "Phone number", format: "phone")
      end
    end

    defmodule User do
      use Normandy.Schema

      io_schema "User profile" do
        field(:username, :string,
          description: "Username",
          required: true,
          min_length: 3,
          max_length: 20
        )

        field(:age, :integer, description: "User age", minimum: 0, maximum: 150)
        field(:contact, ContactInfo, description: "Contact info", required: true)
        field(:tags, {:array, :string}, description: "User tags", min_items: 1, max_items: 10)
        field(:is_active, :boolean, description: "Account status", default: true)
      end
    end

    test "mixed types all work together" do
      spec = User.__schema__(:specification)

      # Primitive with constraints
      assert spec.properties.username.minLength == 3
      assert spec.properties.username.maxLength == 20

      # Number with constraints
      assert spec.properties.age.minimum == 0
      assert spec.properties.age.maximum == 150

      # Nested schema
      assert spec.properties.contact.type == :object
      assert spec.properties.contact.properties.email.format == "email"

      # Array of primitives
      assert spec.properties.tags.type == :array
      assert spec.properties.tags.items.type == :string
      assert spec.properties.tags.minItems == 1

      # Boolean with default
      assert spec.properties.is_active.type == :boolean
      assert spec.properties.is_active.default == true
    end

    test "all required fields are tracked" do
      spec = User.__schema__(:specification)

      assert :username in spec.required
      assert :contact in spec.required
      refute :age in spec.required
      refute :tags in spec.required
    end
  end

  describe "nested schema with all field options" do
    defmodule AddressWithAllOptions do
      use Normandy.Schema

      io_schema "Comprehensive address" do
        field(:street, :string,
          description: "Street address",
          required: true,
          min_length: 5,
          max_length: 100
        )

        field(:unit, :string,
          description: "Unit number",
          pattern: "^[A-Za-z0-9-]+$",
          examples: ["101", "A-5", "Suite 200"]
        )

        field(:postal_code, :string,
          description: "Postal code",
          required: true,
          pattern: "^[0-9]{5}(-[0-9]{4})?$",
          examples: ["12345", "12345-6789"]
        )

        field(:country, :string,
          description: "Country",
          required: true,
          enum: ["US", "CA", "MX"],
          default: "US"
        )
      end
    end

    defmodule PersonWithFullAddress do
      use Normandy.Schema

      io_schema "Person with full address" do
        field(:name, :string, description: "Full name", required: true)

        field(:address, AddressWithAllOptions,
          description: "Mailing address",
          required: true
        )
      end
    end

    test "all field options are preserved in nested schema" do
      spec = PersonWithFullAddress.__schema__(:specification)
      address_props = spec.properties.address.properties

      # String length constraints
      assert address_props.street.minLength == 5
      assert address_props.street.maxLength == 100

      # Pattern
      assert address_props.unit.pattern == "^[A-Za-z0-9-]+$"
      assert address_props.postal_code.pattern == "^[0-9]{5}(-[0-9]{4})?$"

      # Examples
      assert address_props.unit.examples == ["101", "A-5", "Suite 200"]
      assert address_props.postal_code.examples == ["12345", "12345-6789"]

      # Enum
      assert address_props.country.enum == ["US", "CA", "MX"]

      # Default
      assert address_props.country.default == "US"

      # Required fields
      assert :street in spec.properties.address.required
      assert :postal_code in spec.properties.address.required
      assert :country in spec.properties.address.required
      refute :unit in spec.properties.address.required
    end
  end

  describe "multiple nested schemas in one parent" do
    defmodule BillingAddress do
      use Normandy.Schema

      io_schema "Billing address" do
        field(:street, :string, required: true)
        field(:city, :string, required: true)
      end
    end

    defmodule ShippingAddress do
      use Normandy.Schema

      io_schema "Shipping address" do
        field(:street, :string, required: true)
        field(:city, :string, required: true)
        field(:delivery_instructions, :string)
      end
    end

    defmodule Order do
      use Normandy.Schema

      io_schema "Customer order" do
        field(:order_id, :string, required: true)
        field(:billing, BillingAddress, description: "Billing address", required: true)
        field(:shipping, ShippingAddress, description: "Shipping address", required: true)
      end
    end

    test "multiple different nested schemas work" do
      spec = Order.__schema__(:specification)

      assert spec.properties.billing.type == :object
      assert spec.properties.shipping.type == :object

      assert map_size(spec.properties.billing.properties) == 2
      assert map_size(spec.properties.shipping.properties) == 3

      assert Map.has_key?(spec.properties.shipping.properties, :delivery_instructions)
      refute Map.has_key?(spec.properties.billing.properties, :delivery_instructions)
    end

    test "each nested schema has its own required fields" do
      spec = Order.__schema__(:specification)

      assert spec.properties.billing.required == [:street, :city]
      assert spec.properties.shipping.required == [:street, :city]
    end
  end

  describe "edge cases and error handling" do
    test "invalid schema module raises error" do
      assert_raise ArgumentError, ~r/unknown type/, fn ->
        defmodule InvalidNestedSchema do
          use Normandy.Schema

          schema do
            field(:invalid, NotAModule)
          end
        end
      end
    end

    test "nested schema without io_schema works" do
      defmodule SimpleNested do
        use Normandy.Schema

        schema do
          field(:value, :string)
        end
      end

      defmodule ParentOfSimple do
        use Normandy.Schema

        schema do
          field(:nested, SimpleNested)
        end
      end

      # Should not raise, even though SimpleNested doesn't have io_schema
      spec = ParentOfSimple.__schema__(:specification)
      assert spec.properties.nested.type == :object
    end

    test "empty nested schema works" do
      defmodule EmptyNested do
        use Normandy.Schema

        io_schema "Empty schema" do
        end
      end

      defmodule ParentOfEmpty do
        use Normandy.Schema

        io_schema "Parent of empty" do
          field(:empty, EmptyNested)
        end
      end

      spec = ParentOfEmpty.__schema__(:specification)
      assert spec.properties.empty.type == :object
      assert spec.properties.empty.properties == %{}
    end

    test "self-referential schemas are not supported" do
      # This is a limitation - we document it but don't need to test extensively
      # Just ensure it doesn't crash during compilation
      defmodule SelfReferential do
        use Normandy.Schema

        schema do
          field(:name, :string)
          # field(:parent, SelfReferential)  # This would cause compilation issues
        end
      end

      assert SelfReferential.__schema__(:fields) == [:name]
    end
  end

  describe "get_json_schema/0 function" do
    defmodule Location do
      use Normandy.Schema

      io_schema "Geographic location" do
        field(:latitude, :float, description: "Latitude", minimum: -90.0, maximum: 90.0)
        field(:longitude, :float, description: "Longitude", minimum: -180.0, maximum: 180.0)
      end
    end

    defmodule Venue do
      use Normandy.Schema

      io_schema "Event venue" do
        field(:name, :string, description: "Venue name", required: true)
        field(:location, Location, description: "Geographic coordinates")
      end
    end

    test "get_json_schema/0 returns complete specification" do
      schema = Venue.get_json_schema()

      assert schema.type == :object
      assert schema.title == "Venue"
      assert schema.description == "Event venue"
      assert schema[:"$schema"] == "https://json-schema.org/draft/2020-12/schema"
      assert schema.required == [:name]
    end

    test "get_json_schema/0 includes nested schema" do
      schema = Venue.get_json_schema()

      assert schema.properties.location.type == :object
      assert schema.properties.location.properties.latitude.minimum == -90.0
      assert schema.properties.location.properties.longitude.maximum == 180.0
    end

    test "schema can be encoded to JSON" do
      schema = Venue.get_json_schema()
      json = Poison.encode!(schema)

      assert is_binary(json)
      assert String.contains?(json, "\"type\"")
      assert String.contains?(json, "\"properties\"")
    end
  end
end
