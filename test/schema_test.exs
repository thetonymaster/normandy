defmodule Normandy.SchemaTest do
  use ExUnit.Case, async: true

  defmodule Schema do
    use Normandy.Schema

    schema do
      field(:name, :string, default: "eric", description: "name of the user", required: true)
      field(:password, :string, redact: true, required: true)
      field(:count, :integer)
      field(:map, {:map, :string}, default: nil)
      field(:array, {:array, :string})
    end
  end

  defmodule SchemaTestWithDesc do
    use Normandy.Schema

    io_schema "tool with desc" do
      field(:name, :string, default: "eric", description: "name of the user", required: true)
      field(:password, :string, redact: true, required: true)
      field(:count, :integer)
      field(:map, {:map, :string}, default: nil)
      field(:array, {:array, :string})
    end
  end

  test "schema fields" do
    assert Schema.__schema__(:fields) == [:name, :password, :count, :map, :array]
  end

  test "types metadata" do
    assert Schema.__schema__(:type, :name) == :string
    assert Schema.__schema__(:type, :array) == {:array, :string}
  end

  test "specification metadata" do
    assert Schema.__specification__() == %{
             name: :string,
             array: {:array, :string},
             count: :integer,
             map: {:map, :string},
             password: :string
           }
  end

  test "default" do
    assert %Schema{}.name == "eric"
    assert %Schema{}.map == nil
  end

  test "required" do
    assert Schema.__schema__(:required) == [:name, :password]
  end

  test "specification" do
    assert Schema.__schema__(:specification) == %{
             type: :object,
             title: "Schema",
             "$schema": "https://json-schema.org/draft/2020-12/schema",
             properties: %{
               name: %{
                 description: "name of the user",
                 type: :string,
                 default: "eric"
               },
               password: %{
                 description: "",
                 type: :string
               },
               count: %{
                 description: "",
                 type: :integer
               },
               map: %{
                 description: "",
                 type: :object,
                 default: nil
               },
               array: %{
                 description: "",
                 type: :array,
                 items: %{
                   type: :string
                 }
               }
             },
             required: [:name, :password]
           }
  end

  test "specification with description" do
    assert SchemaTestWithDesc.__schema__(:specification) == %{
             type: :object,
             title: "SchemaTestWithDesc",
             description: "tool with desc",
             "$schema": "https://json-schema.org/draft/2020-12/schema",
             properties: %{
               name: %{
                 description: "name of the user",
                 type: :string,
                 default: "eric"
               },
               password: %{
                 description: "",
                 type: :string
               },
               count: %{
                 description: "",
                 type: :integer
               },
               map: %{
                 description: "",
                 type: :object,
                 default: nil
               },
               array: %{
                 description: "",
                 type: :array,
                 items: %{
                   type: :string
                 }
               }
             },
             required: [:name, :password]
           }
  end

  describe "JSON Schema constraints" do
    defmodule StringConstraintSchema do
      use Normandy.Schema

      schema do
        field(:username, :string,
          description: "Username",
          min_length: 3,
          max_length: 20,
          pattern: "^[a-zA-Z0-9_]+$"
        )

        field(:email, :string,
          description: "Email address",
          format: "email"
        )

        field(:status, :string,
          description: "Status",
          enum: ["active", "inactive", "pending"]
        )
      end
    end

    defmodule NumberConstraintSchema do
      use Normandy.Schema

      schema do
        field(:age, :integer,
          description: "Age",
          minimum: 0,
          maximum: 150
        )

        field(:score, :float,
          description: "Score",
          exclusive_minimum: 0.0,
          exclusive_maximum: 100.0
        )

        field(:rating, :integer,
          description: "Rating",
          minimum: 1,
          maximum: 5,
          default: 3
        )
      end
    end

    defmodule ArrayConstraintSchema do
      use Normandy.Schema

      schema do
        field(:tags, {:array, :string},
          description: "Tags",
          min_items: 1,
          max_items: 10,
          unique_items: true
        )

        field(:scores, {:array, :integer},
          description: "Test scores",
          min_items: 3
        )
      end
    end

    defmodule ExamplesSchema do
      use Normandy.Schema

      schema do
        field(:color, :string,
          description: "Favorite color",
          examples: ["red", "blue", "green"]
        )

        field(:quantity, :integer,
          description: "Quantity",
          examples: [1, 5, 10, 100],
          minimum: 1
        )
      end
    end

    test "string constraints in JSON schema" do
      spec = StringConstraintSchema.__schema__(:specification)

      assert spec.properties.username == %{
               type: :string,
               description: "Username",
               minLength: 3,
               maxLength: 20,
               pattern: "^[a-zA-Z0-9_]+$"
             }

      assert spec.properties.email == %{
               type: :string,
               description: "Email address",
               format: "email"
             }

      assert spec.properties.status == %{
               type: :string,
               description: "Status",
               enum: ["active", "inactive", "pending"]
             }
    end

    test "number constraints in JSON schema" do
      spec = NumberConstraintSchema.__schema__(:specification)

      assert spec.properties.age == %{
               type: :integer,
               description: "Age",
               minimum: 0,
               maximum: 150
             }

      assert spec.properties.score == %{
               type: :number,
               description: "Score",
               exclusiveMinimum: 0.0,
               exclusiveMaximum: 100.0
             }

      assert spec.properties.rating == %{
               type: :integer,
               description: "Rating",
               minimum: 1,
               maximum: 5,
               default: 3
             }
    end

    test "array constraints in JSON schema" do
      spec = ArrayConstraintSchema.__schema__(:specification)

      assert spec.properties.tags == %{
               type: :array,
               description: "Tags",
               items: %{type: :string},
               minItems: 1,
               maxItems: 10,
               uniqueItems: true
             }

      assert spec.properties.scores == %{
               type: :array,
               description: "Test scores",
               items: %{type: :integer},
               minItems: 3
             }
    end

    test "examples in JSON schema" do
      spec = ExamplesSchema.__schema__(:specification)

      assert spec.properties.color == %{
               type: :string,
               description: "Favorite color",
               examples: ["red", "blue", "green"]
             }

      assert spec.properties.quantity == %{
               type: :integer,
               description: "Quantity",
               examples: [1, 5, 10, 100],
               minimum: 1
             }
    end

    test "combined constraints work together" do
      defmodule CombinedSchema do
        use Normandy.Schema

        schema do
          field(:name, :string,
            description: "Product name",
            min_length: 1,
            max_length: 100,
            pattern: "^[a-zA-Z0-9 ]+$",
            examples: ["Widget", "Gadget"],
            default: "Unnamed"
          )

          field(:price, :float,
            description: "Price in USD",
            minimum: 0.01,
            maximum: 999_999.99,
            examples: [9.99, 19.99, 99.99]
          )

          field(:categories, {:array, :string},
            description: "Product categories",
            min_items: 1,
            max_items: 5,
            unique_items: true,
            examples: [["electronics"], ["electronics", "computers"]]
          )
        end
      end

      spec = CombinedSchema.__schema__(:specification)

      assert spec.properties.name == %{
               type: :string,
               description: "Product name",
               minLength: 1,
               maxLength: 100,
               pattern: "^[a-zA-Z0-9 ]+$",
               examples: ["Widget", "Gadget"],
               default: "Unnamed"
             }

      assert spec.properties.price == %{
               type: :number,
               description: "Price in USD",
               minimum: 0.01,
               maximum: 999_999.99,
               examples: [9.99, 19.99, 99.99]
             }

      assert spec.properties.categories == %{
               type: :array,
               description: "Product categories",
               items: %{type: :string},
               minItems: 1,
               maxItems: 5,
               uniqueItems: true,
               examples: [["electronics"], ["electronics", "computers"]]
             }
    end

    test "fields without constraints don't have constraint keys" do
      defmodule MinimalSchema do
        use Normandy.Schema

        schema do
          field(:name, :string, description: "Just a name")
          field(:count, :integer)
        end
      end

      spec = MinimalSchema.__schema__(:specification)

      # Should only have type and description, no constraint keys
      assert spec.properties.name == %{
               type: :string,
               description: "Just a name"
             }

      assert spec.properties.count == %{
               type: :integer,
               description: ""
             }
    end
  end
end
