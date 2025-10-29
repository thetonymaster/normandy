defmodule Normandy.Schema.IntrospectionTest do
  use ExUnit.Case, async: true

  alias Normandy.Schema.Introspection

  describe "list_fields/1" do
    defmodule SimpleSchema do
      use Normandy.Schema

      schema do
        field(:id, :integer)
        field(:name, :string)
        field(:email, :string)
      end
    end

    test "returns all field names" do
      fields = Introspection.list_fields(SimpleSchema)
      assert :id in fields
      assert :name in fields
      assert :email in fields
    end
  end

  describe "get_required_fields/1" do
    defmodule RequiredSchema do
      use Normandy.Schema

      schema do
        field(:id, :integer, required: true)
        field(:name, :string, required: true)
        field(:email, :string)
        field(:age, :integer)
      end
    end

    test "returns only required fields" do
      required = Introspection.get_required_fields(RequiredSchema)
      assert :id in required
      assert :name in required
      refute :email in required
      refute :age in required
    end
  end

  describe "get_field_type/2" do
    defmodule TypeSchema do
      use Normandy.Schema

      schema do
        field(:count, :integer)
        field(:name, :string)
        field(:active, :boolean)
        field(:tags, {:array, :string})
      end
    end

    test "returns correct type for each field" do
      assert Introspection.get_field_type(TypeSchema, :count) == :integer
      assert Introspection.get_field_type(TypeSchema, :name) == :string
      assert Introspection.get_field_type(TypeSchema, :active) == :boolean
      assert Introspection.get_field_type(TypeSchema, :tags) == {:array, :string}
    end

    test "returns nil for non-existent field" do
      assert Introspection.get_field_type(TypeSchema, :nonexistent) == nil
    end
  end

  describe "get_field_constraints/2" do
    defmodule ConstraintSchema do
      use Normandy.Schema

      schema do
        field(:username, :string, required: true, min_length: 3, max_length: 20)
        field(:email, :string, format: "email")
        field(:age, :integer, minimum: 0, maximum: 150)
        field(:tags, {:array, :string}, min_items: 1, max_items: 10)
        field(:status, :string, enum: ["active", "inactive"])
      end
    end

    test "returns string constraints" do
      constraints = Introspection.get_field_constraints(ConstraintSchema, :username)
      assert constraints[:required] == true
      assert constraints[:min_length] == 3
      assert constraints[:max_length] == 20
    end

    test "returns format constraint" do
      constraints = Introspection.get_field_constraints(ConstraintSchema, :email)
      assert constraints[:format] == "email"
    end

    test "returns number constraints" do
      constraints = Introspection.get_field_constraints(ConstraintSchema, :age)
      assert constraints[:minimum] == 0
      assert constraints[:maximum] == 150
    end

    test "returns array constraints" do
      constraints = Introspection.get_field_constraints(ConstraintSchema, :tags)
      assert constraints[:min_items] == 1
      assert constraints[:max_items] == 10
    end

    test "returns enum constraint" do
      constraints = Introspection.get_field_constraints(ConstraintSchema, :status)
      assert constraints[:enum] == ["active", "inactive"]
    end

    test "returns empty map for field without constraints" do
      defmodule NoConstraintSchema do
        use Normandy.Schema

        schema do
          field(:data, :string)
        end
      end

      constraints = Introspection.get_field_constraints(NoConstraintSchema, :data)
      assert constraints == %{}
    end
  end

  describe "virtual_field?/2" do
    defmodule VirtualSchema do
      use Normandy.Schema

      schema do
        field(:name, :string)
        field(:computed, :string, virtual: true)
        field(:hidden, :string, virtual: true, include_in_json_schema: false)
      end
    end

    test "returns true for virtual fields excluded from schema" do
      assert Introspection.virtual_field?(VirtualSchema, :hidden) == true
    end

    test "returns false for non-virtual fields" do
      assert Introspection.virtual_field?(VirtualSchema, :name) == false
    end
  end

  describe "get_specification/1" do
    defmodule SpecSchema do
      use Normandy.Schema

      schema do
        field(:id, :integer, required: true)
        field(:name, :string)
      end
    end

    test "returns complete JSON Schema specification" do
      spec = Introspection.get_specification(SpecSchema)
      assert spec[:type] == :object
      assert is_map(spec[:properties])
      assert :id in spec[:required]
    end
  end

  describe "get_description/1" do
    defmodule DescribedSchema do
      use Normandy.Schema

      io_schema "User account information" do
        field(:name, :string)
      end
    end

    test "returns schema description" do
      description = Introspection.get_description(DescribedSchema)
      assert description == "User account information"
    end

    test "returns nil for schema without description" do
      defmodule NoDescSchema do
        use Normandy.Schema

        schema do
          field(:name, :string)
        end
      end

      assert Introspection.get_description(NoDescSchema) == nil
    end
  end

  describe "get_field_metadata/2" do
    defmodule MetadataSchema do
      use Normandy.Schema

      schema do
        field(:id, :integer, required: true, description: "Unique identifier")
        field(:name, :string, min_length: 3, description: "User's full name")
        field(:email, :string, format: "email")
      end
    end

    test "returns complete field metadata" do
      metadata = Introspection.get_field_metadata(MetadataSchema, :name)
      assert metadata[:type] == :string
      assert metadata[:required] == false
      assert metadata[:constraints][:min_length] == 3
      assert metadata[:virtual] == false
      assert metadata[:description] == "User's full name"
    end

    test "returns required status correctly" do
      metadata = Introspection.get_field_metadata(MetadataSchema, :id)
      assert metadata[:required] == true
    end

    test "returns nil for non-existent field" do
      assert Introspection.get_field_metadata(MetadataSchema, :nonexistent) == nil
    end
  end

  describe "list_all_metadata/1" do
    defmodule AllMetadataSchema do
      use Normandy.Schema

      schema do
        field(:id, :integer, required: true)
        field(:name, :string, required: true)
        field(:email, :string)
      end
    end

    test "returns metadata for all fields" do
      all_metadata = Introspection.list_all_metadata(AllMetadataSchema)
      assert is_map(all_metadata)
      assert Map.has_key?(all_metadata, :id)
      assert Map.has_key?(all_metadata, :name)
      assert Map.has_key?(all_metadata, :email)
      assert all_metadata[:id][:required] == true
      assert all_metadata[:name][:required] == true
      assert all_metadata[:email][:required] == false
    end
  end

  describe "has_composition?/1" do
    defmodule PlainSchema do
      use Normandy.Schema

      schema do
        field(:name, :string)
      end
    end

    defmodule CompositionSchema do
      use Normandy.Schema

      schema do
        field(:data, :string, any_of: [%{type: :string}, %{type: :integer}])
      end
    end

    test "returns false for schema without composition" do
      assert Introspection.has_composition?(PlainSchema) == false
    end

    test "returns true for schema with composition" do
      assert Introspection.has_composition?(CompositionSchema) == true
    end
  end

  describe "has_conditionals?/1" do
    defmodule PlainSchema do
      use Normandy.Schema

      schema do
        field(:name, :string)
      end
    end

    defmodule ConditionalSchema do
      use Normandy.Schema

      schema do
        field(:billing_type, :string)

        field(
          :price,
          :integer,
          if_schema: %{properties: %{billing_type: %{const: "subscription"}}},
          then_schema: %{properties: %{price: %{minimum: 10}}}
        )
      end
    end

    test "returns false for schema without conditionals" do
      assert Introspection.has_conditionals?(PlainSchema) == false
    end

    test "returns true for schema with conditionals" do
      assert Introspection.has_conditionals?(ConditionalSchema) == true
    end
  end
end
