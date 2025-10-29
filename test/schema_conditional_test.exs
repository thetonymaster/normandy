defmodule NormandyTest.SchemaConditionalTest do
  use ExUnit.Case, async: true

  describe "basic if/then conditionals" do
    defmodule BasicIfThen do
      use Normandy.Schema

      schema do
        field(:value, :any,
          description: "Value with conditional validation",
          if_schema: %{type: :string},
          then_schema: %{minLength: 5}
        )
      end
    end

    test "generates if and then in JSON Schema" do
      spec = BasicIfThen.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:if]
      assert value_spec[:then]
      refute value_spec[:else]
    end

    test "if schema contains correct condition" do
      spec = BasicIfThen.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:if] == %{type: :string}
    end

    test "then schema contains correct constraint" do
      spec = BasicIfThen.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:then] == %{minLength: 5}
    end

    test "description is preserved with conditionals" do
      spec = BasicIfThen.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:description] == "Value with conditional validation"
    end
  end

  describe "if/then/else conditionals" do
    defmodule IfThenElse do
      use Normandy.Schema

      schema do
        field(:value, :any,
          description: "String or number with different constraints",
          if_schema: %{type: :string},
          then_schema: %{minLength: 5, maxLength: 100},
          else_schema: %{type: :number, minimum: 0}
        )
      end
    end

    test "generates if, then, and else in JSON Schema" do
      spec = IfThenElse.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:if]
      assert value_spec[:then]
      assert value_spec[:else]
    end

    test "if/then/else schemas have correct constraints" do
      spec = IfThenElse.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:if] == %{type: :string}
      assert value_spec[:then] == %{minLength: 5, maxLength: 100}
      assert value_spec[:else] == %{type: :number, minimum: 0}
    end
  end

  describe "if/else without then" do
    defmodule IfElse do
      use Normandy.Schema

      schema do
        field(:value, :any,
          if_schema: %{type: :boolean},
          else_schema: %{type: :integer, minimum: 1}
        )
      end
    end

    test "generates if and else without then" do
      spec = IfElse.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:if]
      assert value_spec[:else]
      refute value_spec[:then]
    end

    test "if and else schemas are correct" do
      spec = IfElse.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:if] == %{type: :boolean}
      assert value_spec[:else] == %{type: :integer, minimum: 1}
    end
  end

  describe "if without then/else" do
    defmodule IfOnly do
      use Normandy.Schema

      schema do
        field(:value, :any, if_schema: %{type: :object, required: [:id]})
      end
    end

    test "generates only if schema" do
      spec = IfOnly.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:if]
      refute value_spec[:then]
      refute value_spec[:else]
    end

    test "if schema is correct" do
      spec = IfOnly.__schema__(:specification)
      value_spec = spec.properties[:value]

      assert value_spec[:if] == %{type: :object, required: [:id]}
    end
  end

  describe "conditionals with schema modules" do
    defmodule PremiumFeatures do
      use Normandy.Schema

      schema do
        field(:max_users, :integer, required: true)
        field(:priority_support, :boolean, default: true)
      end
    end

    defmodule BasicFeatures do
      use Normandy.Schema

      schema do
        field(:max_users, :integer, required: true)
        field(:ads_enabled, :boolean, default: true)
      end
    end

    defmodule SubscriptionPlan do
      use Normandy.Schema

      schema do
        field(:plan, :map,
          description: "Plan details",
          if_schema: %{properties: %{tier: %{const: "premium"}}},
          then_schema: PremiumFeatures,
          else_schema: BasicFeatures
        )
      end
    end

    test "uses schema modules in conditionals" do
      spec = SubscriptionPlan.__schema__(:specification)
      plan_spec = spec.properties[:plan]

      assert plan_spec[:if]
      assert plan_spec[:then]
      assert plan_spec[:else]
    end

    test "if schema has correct condition" do
      spec = SubscriptionPlan.__schema__(:specification)
      plan_spec = spec.properties[:plan]

      assert plan_spec[:if] == %{properties: %{tier: %{const: "premium"}}}
    end

    test "then schema expands to PremiumFeatures" do
      spec = SubscriptionPlan.__schema__(:specification)
      plan_spec = spec.properties[:plan]

      then_schema = plan_spec[:then]
      assert then_schema[:type] == :object
      assert then_schema[:properties][:max_users]
      assert then_schema[:properties][:priority_support]
      assert :max_users in then_schema[:required]
    end

    test "else schema expands to BasicFeatures" do
      spec = SubscriptionPlan.__schema__(:specification)
      plan_spec = spec.properties[:plan]

      else_schema = plan_spec[:else]
      assert else_schema[:type] == :object
      assert else_schema[:properties][:max_users]
      assert else_schema[:properties][:ads_enabled]
      assert :max_users in else_schema[:required]
    end
  end

  describe "nested conditionals" do
    defmodule NestedConditionals do
      use Normandy.Schema

      schema do
        field(:primary, :any,
          if_schema: %{type: :object},
          then_schema: %{
            properties: %{
              nested_value: %{
                if: %{type: :string},
                then: %{minLength: 3}
              }
            }
          }
        )
      end
    end

    test "supports nested conditional schemas" do
      spec = NestedConditionals.__schema__(:specification)
      primary_spec = spec.properties[:primary]

      assert primary_spec[:if] == %{type: :object}

      then_schema = primary_spec[:then]
      assert then_schema[:properties][:nested_value][:if] == %{type: :string}
      assert then_schema[:properties][:nested_value][:then] == %{minLength: 3}
    end
  end

  describe "conditionals with complex conditions" do
    defmodule ComplexCondition do
      use Normandy.Schema

      schema do
        field(:data, :map,
          description: "Data with complex conditional validation",
          if_schema: %{
            properties: %{
              type: %{const: "user"},
              role: %{enum: ["admin", "superuser"]}
            },
            required: [:type, :role]
          },
          then_schema: %{
            properties: %{
              permissions: %{type: :array, minItems: 1}
            },
            required: [:permissions]
          }
        )
      end
    end

    test "handles complex if conditions" do
      spec = ComplexCondition.__schema__(:specification)
      data_spec = spec.properties[:data]

      if_schema = data_spec[:if]
      assert if_schema[:properties][:type][:const] == "user"
      assert if_schema[:properties][:role][:enum] == ["admin", "superuser"]
      assert if_schema[:required] == [:type, :role]
    end

    test "handles complex then schemas" do
      spec = ComplexCondition.__schema__(:specification)
      data_spec = spec.properties[:data]

      then_schema = data_spec[:then]
      assert then_schema[:properties][:permissions][:type] == :array
      assert then_schema[:properties][:permissions][:minItems] == 1
      assert then_schema[:required] == [:permissions]
    end
  end

  describe "conditionals with other field options" do
    defmodule ConditionalWithOptions do
      use Normandy.Schema

      schema do
        field(:value, :any,
          description: "Value with conditionals and other options",
          required: true,
          if_schema: %{type: :string},
          then_schema: %{pattern: "^[A-Z]"},
          examples: ["Hello", 123]
        )
      end
    end

    test "combines conditionals with other field options" do
      spec = ConditionalWithOptions.__schema__(:specification)
      value_spec = spec.properties[:value]

      # Has conditionals
      assert value_spec[:if] == %{type: :string}
      assert value_spec[:then] == %{pattern: "^[A-Z]"}

      # Has other options
      assert value_spec[:description] == "Value with conditionals and other options"
      assert value_spec[:examples] == ["Hello", 123]

      # Required is at schema level
      assert :value in spec.required
    end
  end

  describe "io_schema with conditionals" do
    defmodule IOSchemaWithConditional do
      use Normandy.Schema

      io_schema "Input with conditional validation" do
        field(:input, :any,
          description: "Flexible input",
          required: true,
          if_schema: %{type: :number},
          then_schema: %{minimum: 0, maximum: 100}
        )
      end
    end

    test "conditionals work with io_schema" do
      spec = IOSchemaWithConditional.__schema__(:specification)
      assert spec.description == "Input with conditional validation"

      input_spec = spec.properties[:input]
      assert input_spec[:if] == %{type: :number}
      assert input_spec[:then] == %{minimum: 0, maximum: 100}
    end
  end

  describe "multiple conditionals in one schema" do
    defmodule MultipleConditionals do
      use Normandy.Schema

      schema do
        field(:field1, :any,
          if_schema: %{type: :string},
          then_schema: %{minLength: 1}
        )

        field(:field2, :any,
          if_schema: %{type: :number},
          then_schema: %{minimum: 0},
          else_schema: %{type: :boolean}
        )

        field(:field3, :any,
          if_schema: %{type: :array},
          else_schema: %{type: :object}
        )
      end
    end

    test "multiple fields can have different conditionals" do
      spec = MultipleConditionals.__schema__(:specification)

      field1_spec = spec.properties[:field1]
      assert field1_spec[:if] == %{type: :string}
      assert field1_spec[:then] == %{minLength: 1}
      refute field1_spec[:else]

      field2_spec = spec.properties[:field2]
      assert field2_spec[:if] == %{type: :number}
      assert field2_spec[:then] == %{minimum: 0}
      assert field2_spec[:else] == %{type: :boolean}

      field3_spec = spec.properties[:field3]
      assert field3_spec[:if] == %{type: :array}
      assert field3_spec[:else] == %{type: :object}
      refute field3_spec[:then]
    end
  end

  describe "conditionals with property existence checks" do
    defmodule PropertyExistence do
      use Normandy.Schema

      schema do
        field(:config, :map,
          description: "Configuration with conditional requirements",
          if_schema: %{required: [:api_key]},
          then_schema: %{
            properties: %{
              api_endpoint: %{type: :string, format: "uri"}
            },
            required: [:api_endpoint]
          }
        )
      end
    end

    test "conditionals can check for property existence" do
      spec = PropertyExistence.__schema__(:specification)
      config_spec = spec.properties[:config]

      assert config_spec[:if] == %{required: [:api_key]}

      then_schema = config_spec[:then]
      assert then_schema[:properties][:api_endpoint][:type] == :string
      assert then_schema[:properties][:api_endpoint][:format] == "uri"
      assert then_schema[:required] == [:api_endpoint]
    end
  end

  describe "conditionals without if_schema" do
    defmodule NoIfSchema do
      use Normandy.Schema

      schema do
        field(:value, :string,
          # No if_schema, so then/else should be ignored
          then_schema: %{minLength: 5},
          else_schema: %{maxLength: 10}
        )
      end
    end

    test "then/else are ignored without if_schema" do
      spec = NoIfSchema.__schema__(:specification)
      value_spec = spec.properties[:value]

      refute value_spec[:if]
      refute value_spec[:then]
      refute value_spec[:else]
    end
  end

  describe "conditionals with enum values" do
    defmodule EnumConditional do
      use Normandy.Schema

      schema do
        field(:setting, :map,
          description: "Setting with type-based validation",
          if_schema: %{
            properties: %{
              type: %{const: "percentage"}
            }
          },
          then_schema: %{
            properties: %{
              value: %{type: :number, minimum: 0, maximum: 100}
            }
          },
          else_schema: %{
            properties: %{
              value: %{type: :number, minimum: 0}
            }
          }
        )
      end
    end

    test "conditionals work with const values" do
      spec = EnumConditional.__schema__(:specification)
      setting_spec = spec.properties[:setting]

      assert setting_spec[:if][:properties][:type][:const] == "percentage"
      assert setting_spec[:then][:properties][:value][:maximum] == 100
      refute setting_spec[:else][:properties][:value][:maximum]
    end
  end

  describe "real-world example: subscription tiers" do
    defmodule FreeFeatures do
      use Normandy.Schema

      schema do
        field(:storage_gb, :integer, default: 5)
        field(:users, :integer, default: 1)
      end
    end

    defmodule PaidFeatures do
      use Normandy.Schema

      schema do
        field(:storage_gb, :integer, required: true)
        field(:users, :integer, required: true)
        field(:custom_domain, :boolean, default: true)
        field(:priority_support, :boolean, default: true)
      end
    end

    defmodule Subscription do
      use Normandy.Schema

      schema do
        field(:tier, :string, enum: ["free", "pro", "enterprise"], required: true)

        field(:features, :map,
          description: "Features available for this subscription",
          if_schema: %{
            properties: %{tier: %{enum: ["pro", "enterprise"]}}
          },
          then_schema: PaidFeatures,
          else_schema: FreeFeatures
        )

        field(:price, :float,
          description: "Monthly price",
          if_schema: %{
            properties: %{tier: %{const: "free"}}
          },
          then_schema: %{const: 0.0},
          else_schema: %{minimum: 0.01}
        )
      end
    end

    test "subscription schema has correct structure" do
      spec = Subscription.__schema__(:specification)

      assert spec.properties[:tier][:enum] == ["free", "pro", "enterprise"]
      assert :tier in spec.required
    end

    test "features conditional uses schema modules" do
      spec = Subscription.__schema__(:specification)
      features_spec = spec.properties[:features]

      # Check if condition
      assert features_spec[:if][:properties][:tier][:enum] == ["pro", "enterprise"]

      # Check then schema (PaidFeatures)
      then_schema = features_spec[:then]
      assert then_schema[:type] == :object
      assert then_schema[:properties][:storage_gb]
      assert then_schema[:properties][:custom_domain]
      assert then_schema[:properties][:priority_support]

      # Check else schema (FreeFeatures)
      else_schema = features_spec[:else]
      assert else_schema[:type] == :object
      assert else_schema[:properties][:storage_gb][:default] == 5
      assert else_schema[:properties][:users][:default] == 1
    end

    test "price conditional ensures free tier is $0" do
      spec = Subscription.__schema__(:specification)
      price_spec = spec.properties[:price]

      assert price_spec[:if][:properties][:tier][:const] == "free"
      assert price_spec[:then][:const] == 0.0
      assert price_spec[:else][:minimum] == 0.01
    end
  end

  describe "combining conditionals with composition" do
    defmodule ConditionalWithComposition do
      use Normandy.Schema

      schema do
        field(:value, :any,
          description: "Value that can be string or number with conditional constraints",
          any_of: [
            %{type: :string},
            %{type: :number}
          ],
          if_schema: %{type: :string},
          then_schema: %{minLength: 3}
        )
      end
    end

    test "combines anyOf with conditionals" do
      spec = ConditionalWithComposition.__schema__(:specification)
      value_spec = spec.properties[:value]

      # Has composition
      assert value_spec[:anyOf]
      assert length(value_spec[:anyOf]) == 2

      # Has conditionals
      assert value_spec[:if] == %{type: :string}
      assert value_spec[:then] == %{minLength: 3}
    end
  end
end
