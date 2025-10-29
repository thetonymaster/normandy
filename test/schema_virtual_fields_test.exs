defmodule NormandyTest.SchemaVirtualFieldsTest do
  use ExUnit.Case, async: true

  describe "virtual fields" do
    defmodule SimpleVirtual do
      use Normandy.Schema

      schema do
        field(:name, :string, required: true)
        field(:age, :integer, required: true)
        field(:metadata, :map, virtual: true)
      end
    end

    test "virtual fields exist in the struct" do
      schema = %SimpleVirtual{name: "Alice", age: 30, metadata: %{foo: "bar"}}
      assert schema.name == "Alice"
      assert schema.age == 30
      assert schema.metadata == %{foo: "bar"}
    end

    test "virtual fields are tracked separately via __schema__/1" do
      assert [:metadata] = SimpleVirtual.__schema__(:virtual_fields)
    end

    test "virtual fields are excluded from JSON Schema by default" do
      spec = SimpleVirtual.__schema__(:specification)
      properties = Map.keys(spec.properties)

      assert :name in properties
      assert :age in properties
      refute :metadata in properties
    end

    test "virtual fields are in the fields list" do
      fields = SimpleVirtual.__schema__(:fields)
      assert :name in fields
      assert :age in fields
      assert :metadata in fields
    end

    test "virtual fields are not in required list" do
      required = SimpleVirtual.__schema__(:required)
      assert :name in required
      assert :age in required
      refute :metadata in required
    end
  end

  describe "virtual fields with include_in_json_schema" do
    defmodule VirtualIncludedInSchema do
      use Normandy.Schema

      schema do
        field(:id, :string, required: true)
        field(:internal_data, :map, virtual: true)
        field(:public_metadata, :map, virtual: true, include_in_json_schema: true)
      end
    end

    test "virtual fields with include_in_json_schema are in JSON Schema" do
      spec = VirtualIncludedInSchema.__schema__(:specification)
      properties = Map.keys(spec.properties)

      assert :id in properties
      assert :public_metadata in properties
      refute :internal_data in properties
    end

    test "both virtual fields are tracked as virtual" do
      virtual_fields = VirtualIncludedInSchema.__schema__(:virtual_fields)
      assert :internal_data in virtual_fields
      assert :public_metadata in virtual_fields
    end
  end

  describe "computed fields" do
    defmodule ComputedFields do
      use Normandy.Schema

      defp compute_total(%{price: price, tax_rate: rate}) do
        price * (1 + rate)
      end

      schema do
        field(:price, :float, required: true)
        field(:tax_rate, :float, default: 0.1)
        field(:total_price, :float, virtual: true, compute: &__MODULE__.compute_total/1)
      end
    end

    test "computed fields are tracked with their compute function" do
      computed_fields = ComputedFields.__schema__(:computed_fields)
      assert [{:total_price, compute_fn}] = computed_fields
      assert is_function(compute_fn, 1)
    end

    test "computed fields are excluded from JSON Schema" do
      spec = ComputedFields.__schema__(:specification)
      properties = Map.keys(spec.properties)

      assert :price in properties
      assert :tax_rate in properties
      refute :total_price in properties
    end

    test "computed fields exist in the struct" do
      schema = %ComputedFields{price: 100.0, tax_rate: 0.2, total_price: 120.0}
      assert schema.price == 100.0
      assert schema.tax_rate == 0.2
      assert schema.total_price == 120.0
    end
  end

  describe "computed fields with include_in_json_schema" do
    defmodule ComputedIncludedInSchema do
      use Normandy.Schema

      defp compute_full_name(%{first_name: first, last_name: last}) do
        "#{first} #{last}"
      end

      schema do
        field(:first_name, :string, required: true)
        field(:last_name, :string, required: true)

        field(:full_name, :string,
          virtual: true,
          compute: &__MODULE__.compute_full_name/1,
          include_in_json_schema: true
        )
      end
    end

    test "computed fields with include_in_json_schema are in JSON Schema" do
      spec = ComputedIncludedInSchema.__schema__(:specification)
      properties = Map.keys(spec.properties)

      assert :first_name in properties
      assert :last_name in properties
      assert :full_name in properties
    end

    test "computed field is tracked as both virtual and computed" do
      virtual_fields = ComputedIncludedInSchema.__schema__(:virtual_fields)
      assert [:full_name] = virtual_fields

      computed_fields = ComputedIncludedInSchema.__schema__(:computed_fields)
      assert [{:full_name, _compute_fn}] = computed_fields
    end
  end

  describe "virtual field validation errors" do
    test "virtual fields cannot be required" do
      assert_raise ArgumentError, ~r/virtual field `status` cannot be required/, fn ->
        defmodule InvalidVirtualRequired do
          use Normandy.Schema

          schema do
            field(:name, :string)
            field(:status, :string, virtual: true, required: true)
          end
        end
      end
    end
  end

  describe "io_schema with virtual fields" do
    defmodule IOSchemaWithVirtual do
      use Normandy.Schema

      io_schema "Test schema with virtual fields" do
        field(:input_data, :string, description: "Input data", required: true)
        field(:processed_data, :string, description: "Processed result", virtual: true)

        field(:debug_info, :map,
          description: "Debug information",
          virtual: true,
          include_in_json_schema: true
        )
      end
    end

    test "virtual fields work with io_schema" do
      virtual_fields = IOSchemaWithVirtual.__schema__(:virtual_fields)
      assert :processed_data in virtual_fields
      assert :debug_info in virtual_fields
    end

    test "JSON Schema includes only fields with include_in_json_schema" do
      spec = IOSchemaWithVirtual.__schema__(:specification)
      properties = Map.keys(spec.properties)

      assert :input_data in properties
      assert :debug_info in properties
      refute :processed_data in properties
    end

    test "JSON Schema specification has correct description" do
      spec = IOSchemaWithVirtual.__schema__(:specification)
      assert spec.description == "Test schema with virtual fields"
    end
  end

  describe "virtual fields with default values" do
    defmodule VirtualWithDefaults do
      use Normandy.Schema

      schema do
        field(:name, :string, required: true)
        field(:cache, :map, virtual: true, default: %{})
        field(:counter, :integer, virtual: true, default: 0)
      end
    end

    test "virtual fields can have default values" do
      schema = %VirtualWithDefaults{name: "Test"}
      assert schema.name == "Test"
      assert schema.cache == %{}
      assert schema.counter == 0
    end

    test "default values work when explicitly setting struct fields" do
      schema = struct!(VirtualWithDefaults, name: "Test")
      assert schema.cache == %{}
      assert schema.counter == 0
    end
  end

  describe "multiple virtual fields" do
    defmodule MultipleVirtual do
      use Normandy.Schema

      defp compute_value(_), do: 3.14

      schema do
        field(:id, :string, required: true)
        field(:data, :string, required: true)
        field(:virtual1, :string, virtual: true)
        field(:virtual2, :integer, virtual: true)
        field(:virtual3, :map, virtual: true, include_in_json_schema: true)
        field(:computed1, :float, virtual: true, compute: &__MODULE__.compute_value/1)
      end
    end

    test "all virtual fields are tracked" do
      virtual_fields = MultipleVirtual.__schema__(:virtual_fields)
      assert length(virtual_fields) == 4
      assert :virtual1 in virtual_fields
      assert :virtual2 in virtual_fields
      assert :virtual3 in virtual_fields
      assert :computed1 in virtual_fields
    end

    test "computed fields are tracked separately" do
      computed_fields = MultipleVirtual.__schema__(:computed_fields)
      assert [{:computed1, _}] = computed_fields
    end

    test "JSON Schema only includes non-virtual and explicitly included virtual fields" do
      spec = MultipleVirtual.__schema__(:specification)
      properties = Map.keys(spec.properties)

      assert :id in properties
      assert :data in properties
      assert :virtual3 in properties
      refute :virtual1 in properties
      refute :virtual2 in properties
      refute :computed1 in properties
    end
  end

  describe "virtual fields with all types" do
    defmodule VirtualAllTypes do
      use Normandy.Schema

      schema do
        field(:v_string, :string, virtual: true)
        field(:v_integer, :integer, virtual: true)
        field(:v_float, :float, virtual: true)
        field(:v_boolean, :boolean, virtual: true)
        field(:v_map, :map, virtual: true)
        field(:v_array, {:array, :string}, virtual: true)
        field(:v_date, :date, virtual: true)
        field(:v_time, :time, virtual: true)
      end
    end

    test "virtual fields work with all type primitives" do
      virtual_fields = VirtualAllTypes.__schema__(:virtual_fields)
      assert length(virtual_fields) == 8
    end

    test "all virtual fields are excluded from JSON Schema" do
      spec = VirtualAllTypes.__schema__(:specification)
      assert spec.properties == %{}
    end

    test "struct can be created with all virtual field types" do
      schema = %VirtualAllTypes{
        v_string: "test",
        v_integer: 42,
        v_float: 3.14,
        v_boolean: true,
        v_map: %{key: "value"},
        v_array: ["a", "b"],
        v_date: ~D[2024-01-01],
        v_time: ~T[12:00:00]
      }

      assert schema.v_string == "test"
      assert schema.v_integer == 42
      assert schema.v_float == 3.14
      assert schema.v_boolean == true
      assert schema.v_map == %{key: "value"}
      assert schema.v_array == ["a", "b"]
      assert schema.v_date == ~D[2024-01-01]
      assert schema.v_time == ~T[12:00:00]
    end
  end

  describe "virtual fields with nested schemas" do
    defmodule NestedSchema do
      use Normandy.Schema

      schema do
        field(:name, :string, required: true)
      end
    end

    defmodule ParentWithVirtualNested do
      use Normandy.Schema

      schema do
        field(:id, :string, required: true)
        field(:nested, NestedSchema, virtual: true)
        field(:nested_array, {:array, NestedSchema}, virtual: true)
      end
    end

    test "virtual fields work with nested schemas" do
      virtual_fields = ParentWithVirtualNested.__schema__(:virtual_fields)
      assert :nested in virtual_fields
      assert :nested_array in virtual_fields
    end

    test "virtual nested schemas are excluded from JSON Schema" do
      spec = ParentWithVirtualNested.__schema__(:specification)
      properties = Map.keys(spec.properties)

      assert :id in properties
      refute :nested in properties
      refute :nested_array in properties
    end

    test "struct can be created with virtual nested schemas" do
      nested = %NestedSchema{name: "Test"}
      schema = %ParentWithVirtualNested{id: "1", nested: nested, nested_array: [nested]}

      assert schema.id == "1"
      assert schema.nested.name == "Test"
      assert [%NestedSchema{name: "Test"}] = schema.nested_array
    end
  end
end
