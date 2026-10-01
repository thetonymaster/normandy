defmodule Normandy.Schema do
  @moduledoc """
  Provides a macro-based DSL for defining structured data schemas.

  This module allows you to define structs with typed fields, default values,
  validation rules, and metadata. It's the foundation for defining agents,
  messages, and other structured data in Normandy.

  ## Features

  - Type-safe field definitions
  - Nested schema support with inline JSON Schema generation
  - JSON Schema composition (anyOf, oneOf, allOf)
  - Conditional schemas (if/then/else)
  - Virtual and computed fields
  - Default value support
  - Field-level validation with JSON Schema constraints
  - Automatic struct generation
  - Metadata tracking
  - Field redaction: a `redact: true` field is left out of `inspect/1`, of the
    JSON an `io_schema` sends to the model (`to_json/1`, `__str__/1`,
    `__rich__/1`) and of `Normandy.InvalidChangesetError` messages. Do not
    redact a value the model needs to see.
  - JSON Schema export for LLM tool calling

  ## Example

      defmodule User do
        use Normandy.Schema

        schema do
          field(:name, :string, required: true)
          field(:age, :integer, default: 0)
          field(:email, :string, required: true)
        end
      end

      user = %User{name: "Alice", email: "alice@example.com"}

  ## Nested Schemas

  Normandy supports nested schemas with full JSON Schema generation:

      defmodule Address do
        use Normandy.Schema

        io_schema "Address information" do
          field(:street, :string, description: "Street address", required: true)
          field(:city, :string, description: "City name", required: true)
          field(:postal_code, :string, description: "Postal code", pattern: "^[0-9]{5}$")
        end
      end

      defmodule User do
        use Normandy.Schema

        io_schema "User profile" do
          field(:name, :string, description: "Full name", required: true)
          # Single nested schema
          field(:address, Address, description: "Primary address", required: true)
          # Array of nested schemas
          field(:previous_addresses, {:array, Address}, description: "Previous addresses")
        end
      end

      # Export as JSON Schema
      schema = User.get_json_schema()
      # Nested schemas are inlined with all constraints preserved

  ## JSON Schema Composition

  Normandy supports JSON Schema composition using `anyOf`, `oneOf`, and `allOf`:

      defmodule StringOrNumber do
        use Normandy.Schema

        schema do
          # Field can be either string or number
          field(:value, :any,
            description: "String or number value",
            one_of: [
              %{type: :string, minLength: 1},
              %{type: :number, minimum: 0}
            ]
          )
        end
      end

  You can also reference schema modules in composition:

      defmodule EmailContact do
        use Normandy.Schema
        schema do
          field(:email, :string, required: true)
        end
      end

      defmodule PhoneContact do
        use Normandy.Schema
        schema do
          field(:phone, :string, required: true)
        end
      end

      defmodule Contact do
        use Normandy.Schema

        schema do
          # Contact must have either email or phone
          field(:contact_info, :map,
            one_of: [EmailContact, PhoneContact]
          )
        end
      end

  Composition options:

  - `:any_of` - Value must match at least one of the schemas
  - `:one_of` - Value must match exactly one of the schemas
  - `:all_of` - Value must match all of the schemas

  ## Conditional Schemas

  Normandy supports JSON Schema conditional validation using `if`, `then`, and `else`:

      defmodule ConditionalSchema do
        use Normandy.Schema

        schema do
          # If type is "premium", then price must be >= 100
          field(:subscription, :map,
            description: "Subscription details",
            if_schema: %{properties: %{type: %{const: "premium"}}},
            then_schema: %{properties: %{price: %{minimum: 100}}}
          )
        end
      end

  You can use `if`/`then`/`else` together:

      field(:value, :any,
        if_schema: %{type: :string},
        then_schema: %{minLength: 5},
        else_schema: %{minimum: 0}
      )

  Conditional options:

  - `:if_schema` - Condition to check (required for conditionals)
  - `:then_schema` - Schema to apply if condition is true
  - `:else_schema` - Schema to apply if condition is false

  ## Virtual Fields

  Virtual fields exist in the struct but are not included in JSON Schema by default.
  They can be used for computed values or runtime-only data:

      defmodule Product do
        use Normandy.Schema

        # Must be public: the capture is called from outside the module.
        def compute_total(%{price: price, tax_rate: rate}) do
          price * (1 + rate)
        end

        schema do
          field(:price, :float, required: true)
          field(:tax_rate, :float, default: 0.1)
          # Virtual field computed from other fields
          field(:total_price, :float, virtual: true, compute: &__MODULE__.compute_total/1)
          # Virtual field that is included in JSON Schema
          field(:metadata, :map, virtual: true, include_in_json_schema: true)
        end
      end

  Virtual field options:

  - `:virtual` - Mark field as virtual (excluded from JSON Schema by default)
  - `:compute` - Function to compute the field value from the struct, applied by
    `Normandy.Schema.compute/1` and by `Normandy.Validate.apply_changes/1`
  - `:include_in_json_schema` - Include virtual field in JSON Schema

  Note: Virtual fields cannot be marked as `:required` since they are computed or runtime-only.

  ## Field Options

  All field types support the following options:

  - `:description` - Field description for JSON Schema
  - `:required` - Mark field as required
  - `:default` - Default value for the field
  - `:examples` - Example values for documentation

  ### String Constraints

  - `:min_length` - Minimum string length
  - `:max_length` - Maximum string length
  - `:pattern` - Regular expression pattern (string)
  - `:format` - String format (e.g., "email", "uri", "uuid")
  - `:enum` - List of allowed values

  ### Number Constraints

  - `:minimum` - Minimum value (inclusive)
  - `:maximum` - Maximum value (inclusive)
  - `:exclusive_minimum` - Minimum value (exclusive)
  - `:exclusive_maximum` - Maximum value (exclusive)

  ### Array Constraints

  - `:min_items` - Minimum number of items
  - `:max_items` - Maximum number of items
  - `:unique_items` - Whether items must be unique
  """

  alias Normandy.Metadata

  @field_opts [
    :default,
    :redact,
    :skip_default_validation,
    :description,
    :required,
    # Virtual field options
    :virtual,
    :compute,
    :include_in_json_schema,
    # String constraints
    :min_length,
    :max_length,
    :pattern,
    :format,
    :enum,
    # Number constraints
    :minimum,
    :maximum,
    :exclusive_minimum,
    :exclusive_maximum,
    # Array constraints
    :min_items,
    :max_items,
    :unique_items,
    # JSON Schema composition
    :any_of,
    :one_of,
    :all_of,
    # Conditional schemas
    :if_schema,
    :then_schema,
    :else_schema,
    # Additional metadata
    :examples
  ]

  @type schema :: %{optional(atom) => any, __struct__: atom, __meta__: Metadata.t()}
  @type t :: schema

  @doc false
  # The JSON Schema to show a model for a response struct: the full
  # `__schema__(:specification)` (types, descriptions, required) for a Normandy
  # schema; `__specification__/0` for a struct that only defines that; nil when
  # the struct has no schema at all.
  @spec json_schema(struct()) :: map() | nil
  def json_schema(%mod{}) do
    _ = Code.ensure_loaded(mod)

    cond do
      function_exported?(mod, :__schema__, 1) -> mod.__schema__(:specification)
      function_exported?(mod, :__specification__, 0) -> mod.__specification__()
      true -> nil
    end
  end

  @doc """
  Fills every `compute:` field of a schema struct, in declaration order. Each
  compute function receives the struct, including fields computed before it.
  `Normandy.Validate.apply_changes/1` calls this, so cast results are computed.
  """
  @spec compute(struct()) :: struct()
  def compute(%mod{} = struct) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1) do
      Enum.reduce(mod.__schema__(:computed_fields), struct, fn {field, fun}, acc ->
        Map.put(acc, field, fun.(acc))
      end)
    else
      struct
    end
  end

  @doc false
  defmacro __using__(_) do
    quote do
      import Normandy.Schema, only: [schema: 1, io_schema: 2]

      Module.register_attribute(__MODULE__, :schema_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_raw, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_redact_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_virtual_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_computed_fields, accumulate: true)
    end
  end

  @doc false
  defmacro schema(do: block) do
    prelude =
      quote do
        Normandy.Schema.__schema__(__MODULE__, __ENV__.line)

        try do
          import Normandy.Schema
          unquote(block)
        after
          :ok
        end
      end

    postlude =
      quote unquote: false do
        {struct_fields, bags_of_clauses} = Normandy.Schema.__schema__(__MODULE__)
        defstruct struct_fields

        def __specification__ do
          %{unquote_splicing(Macro.escape(@schema_specification_fields))}
        end

        for clauses <- bags_of_clauses, {args, body} <- clauses do
          def __schema__(unquote_splicing(args)), do: unquote(body)
        end

        :ok
      end

    quote do
      unquote(prelude)
      unquote(postlude)
    end
  end

  @doc false
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defmacro io_schema(source, do: block) do
    prelude =
      quote do
        Normandy.Schema.__schema__(__MODULE__, __ENV__.line)
        source = unquote(source)

        try do
          @description source
          import Normandy.Schema
          unquote(block)
        after
          :ok
        end
      end

    postlude =
      quote unquote: false do
        {struct_fields, bags_of_clauses} = Normandy.Schema.__schema__(__MODULE__)
        defstruct struct_fields

        def __specification__ do
          %{unquote_splicing(Macro.escape(@schema_specification_fields))}
        end

        for clauses <- bags_of_clauses, {args, body} <- clauses do
          def __schema__(unquote_splicing(args)), do: unquote(body)
        end

        try do
          defimpl Normandy.Components.BaseIOSchema, for: __MODULE__ do
            @adapter Application.compile_env(:normandy, :adapter, Poison)
            def __str__(str), do: @adapter.encode!(serializable(str))
            def __rich__(str), do: @adapter.encode!(serializable(str), pretty: true)
            def to_json(str), do: @adapter.encode!(serializable(str))

            # __meta__ is internal bookkeeping (module name, load state) and a
            # redact: true field is hidden everywhere, so neither goes to the
            # model or out. Removing the keys keeps a @derive'd encoder in
            # charge of the remaining fields.
            defp serializable(str),
              do: Map.drop(str, [:__meta__ | str.__struct__.__schema__(:redact_fields)])

            def get_schema(str), do: str.__struct__.get_json_schema()
          end

          def get_json_schema do
            __MODULE__.__schema__(:specification)
          end
        after
          :ok
        end
      end

    quote do
      unquote(prelude)
      unquote(postlude)
    end
  end

  defmacro field(name, type \\ :string, opts \\ []) do
    quote do
      Normandy.Schema.__field__(__MODULE__, unquote(name), unquote(type), unquote(opts))
    end
  end

  @doc false
  def __field__(mod, name, type, opts) do
    # Check the field type before we check options because it is
    # better to raise unknown type first than unsupported option.
    type = check_field_type!(mod, name, type, opts)

    check_options!(type, opts, @field_opts, "field/3")
    check_option_values!(name, opts)
    Module.put_attribute(mod, :schema_specification_fields, {name, type})
    validate_default!(type, opts[:default], opts[:skip_default_validation])
    define_field(mod, name, type, opts)
  end

  @doc false
  def __after_verify__(_module) do
    # If we are compiling code, we can validate associations now,
    # as the Elixir compiler will solve dependencies.

    :ok
  end

  @doc false
  def __schema__(module, line) do
    if previous_line = Module.get_attribute(module, :schema_schema_defined) do
      raise "schema already defined for #{inspect(module)} on line #{previous_line}"
    end

    Module.put_attribute(module, :schema_schema_defined, line)

    if Code.can_await_module_compilation?() do
      Module.put_attribute(module, :after_verify, Normandy.Schema)
    end

    Module.register_attribute(module, :schema_specification_fields, accumulate: true)
    Module.register_attribute(module, :schema_struct_fields, accumulate: true)
    Module.register_attribute(module, :schema_required_fields, accumulate: true)

    context = Module.get_attribute(module, :schema_context)

    meta = %Metadata{
      state: :built,
      context: context,
      schema: module
    }

    Module.put_attribute(module, :schema_struct_fields, {:__meta__, meta})
  end

  @doc false
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def __schema__(module) do
    fields = Module.get_attribute(module, :schema_fields) |> Enum.reverse()
    struct_fields = Module.get_attribute(module, :schema_struct_fields) |> Enum.reverse()
    redacted_fields = Module.get_attribute(module, :schema_redact_fields)
    derive = Module.get_attribute(module, :derive)
    required_fields = Module.get_attribute(module, :schema_required_fields, []) |> Enum.reverse()
    description = Module.get_attribute(module, :description, nil)
    virtual_fields = Module.get_attribute(module, :schema_virtual_fields, []) |> Enum.reverse()
    computed_fields = Module.get_attribute(module, :schema_computed_fields, []) |> Enum.reverse()

    if redacted_fields != [] and not List.keymember?(derive, Inspect, 0) and
         derive_inspect?(module) do
      Module.put_attribute(module, :derive, {Inspect, except: redacted_fields})
    end

    loaded =
      case Map.new([{:__struct__, module} | struct_fields]) do
        %{__meta__: meta} = struct -> %{struct | __meta__: Map.put(meta, :state, :loaded)}
        struct -> struct
      end

    dump =
      for {name, {type, _description, _opts}} <- fields do
        {name, {name, type}}
      end

    types_quoted =
      for {name, {type, _description, _opts}} <- fields do
        {[:type, name], Macro.escape(type)}
      end

    specification = %{
      title: module |> to_string() |> String.split(".") |> List.last(),
      type: :object,
      "$schema": "https://json-schema.org/draft/2020-12/schema"
    }

    specification =
      if description != nil do
        Map.put(specification, :description, description)
      else
        specification
      end

    # Filter out virtual fields from JSON Schema properties unless explicitly included
    properties =
      for {name, {type, description, opts}} <- fields,
          not (Keyword.get(opts, :virtual, false) and
                 not Keyword.get(opts, :include_in_json_schema, false)) do
        build_property_spec(name, type, description, opts)
      end

    specification =
      specification
      |> Map.put(:properties, Map.new(properties))
      |> set_required(required_fields)

    single_arg = [
      {[:dump], dump |> Map.new() |> Macro.escape()},
      {[:redact_fields], redacted_fields},
      {[:required], required_fields},
      {[:fields], Enum.map(fields, &elem(&1, 0))},
      {[:loaded], Macro.escape(loaded)},
      {[:specification], Macro.escape(specification)},
      {[:virtual_fields], virtual_fields},
      {[:computed_fields], Macro.escape(computed_fields)}
    ]

    catch_all = [
      {[:type, quote(do: _)], nil}
    ]

    bags_of_clauses =
      [
        single_arg,
        types_quoted,
        catch_all
      ]

    {struct_fields, bags_of_clauses}
  end

  defp set_required(specification, []), do: specification
  defp set_required(specification, required), do: Map.put(specification, :required, required)

  defp derive_inspect?(module) do
    Module.get_attribute(module, :derive_inspect_for_redacted_fields, true)
  end

  # New function that builds complete property spec with constraints
  defp build_property_spec(name, type, description, opts) do
    base_spec = get_base_type_spec(type, description)
    spec_with_constraints = add_constraints(base_spec, type, opts)
    {name, spec_with_constraints}
  end

  # Get base JSON Schema type specification
  defp get_base_type_spec(type, description) do
    Map.put(json_type(type), :description, description)
  end

  # Maps a Normandy field type to its JSON Schema fragment. A custom or
  # parameterized type uses the base type it declares; a type with no JSON
  # equivalent (`:any`, or a custom type/0 that is not a base type) gets no
  # `type` key, which JSON Schema reads as "any value".
  defp json_type({:array, inner}), do: %{type: :array, items: json_type(inner)}
  defp json_type({:map, inner}), do: %{type: :object, additionalProperties: json_type(inner)}
  defp json_type({:parameterized, {mod, params}}), do: json_type(mod.type(params))
  defp json_type(:float), do: %{type: :number}
  defp json_type(:map), do: %{type: :object}
  defp json_type(:struct), do: %{type: :object}
  defp json_type(t) when t in [:binary, :bitstring], do: %{type: :string}
  defp json_type(:date), do: %{type: :string, format: "date"}
  defp json_type(:time), do: %{type: :string, format: "time"}
  defp json_type(:duration), do: %{type: :string, format: "duration"}
  defp json_type(t) when t in [:string, :integer, :boolean], do: %{type: t}

  defp json_type(mod) when is_atom(mod) do
    cond do
      schema_module?(mod) ->
        inline_nested_schema(mod)

      Code.ensure_compiled(mod) == {:module, mod} and function_exported?(mod, :type, 0) ->
        json_type(mod.type())

      true ->
        %{}
    end
  end

  # Add JSON Schema constraints based on field options
  defp add_constraints(spec, _type, opts) do
    spec
    |> add_string_constraints(opts)
    |> add_number_constraints(opts)
    |> add_array_constraints(opts)
    |> add_enum_constraint(opts)
    |> add_composition_constraints(opts)
    |> add_conditional_constraints(opts)
    |> add_default_value(opts)
    |> add_examples(opts)
  end

  # String constraints
  defp add_string_constraints(spec, opts) do
    spec
    |> maybe_put(:minLength, opts[:min_length])
    |> maybe_put(:maxLength, opts[:max_length])
    |> maybe_put(:pattern, opts[:pattern])
    |> maybe_put(:format, opts[:format])
  end

  # Number constraints
  defp add_number_constraints(spec, opts) do
    spec
    |> maybe_put(:minimum, opts[:minimum])
    |> maybe_put(:maximum, opts[:maximum])
    |> maybe_put(:exclusiveMinimum, opts[:exclusive_minimum])
    |> maybe_put(:exclusiveMaximum, opts[:exclusive_maximum])
  end

  # Array constraints
  defp add_array_constraints(spec, opts) do
    spec
    |> maybe_put(:minItems, opts[:min_items])
    |> maybe_put(:maxItems, opts[:max_items])
    |> maybe_put(:uniqueItems, opts[:unique_items])
  end

  # Enum constraint (applies to any type)
  defp add_enum_constraint(spec, opts) do
    maybe_put(spec, :enum, opts[:enum])
  end

  # JSON Schema composition constraints (anyOf, oneOf, allOf)
  defp add_composition_constraints(spec, opts) do
    spec
    |> add_any_of(opts)
    |> add_one_of(opts)
    |> add_all_of(opts)
  end

  defp add_any_of(spec, opts) do
    case opts[:any_of] do
      nil ->
        spec

      schemas when is_list(schemas) ->
        any_of = Enum.map(schemas, &build_composition_schema/1)
        Map.put(spec, :anyOf, any_of)
    end
  end

  defp add_one_of(spec, opts) do
    case opts[:one_of] do
      nil ->
        spec

      schemas when is_list(schemas) ->
        one_of = Enum.map(schemas, &build_composition_schema/1)
        Map.put(spec, :oneOf, one_of)
    end
  end

  defp add_all_of(spec, opts) do
    case opts[:all_of] do
      nil ->
        spec

      schemas when is_list(schemas) ->
        all_of = Enum.map(schemas, &build_composition_schema/1)
        Map.put(spec, :allOf, all_of)
    end
  end

  # Build a schema for composition (handles both module references and inline specs)
  defp build_composition_schema(schema_module) when is_atom(schema_module) do
    if schema_module?(schema_module) do
      inline_nested_schema(schema_module)
    else
      raise ArgumentError, "Module #{inspect(schema_module)} is not a valid schema in composition"
    end
  end

  defp build_composition_schema(schema_spec) when is_map(schema_spec) do
    # Allow inline schema specifications like %{type: :string, minLength: 5}
    schema_spec
  end

  defp build_composition_schema(invalid) do
    raise ArgumentError,
          "Invalid composition schema: #{inspect(invalid)}. Expected a schema module or map."
  end

  # JSON Schema conditional constraints (if/then/else)
  defp add_conditional_constraints(spec, opts) do
    if_schema = opts[:if_schema]
    then_schema = opts[:then_schema]
    else_schema = opts[:else_schema]

    cond do
      # Must have if_schema to use conditionals
      is_nil(if_schema) ->
        spec

      # if with then and else
      not is_nil(then_schema) and not is_nil(else_schema) ->
        spec
        |> Map.put(:if, build_conditional_schema(if_schema))
        |> Map.put(:then, build_conditional_schema(then_schema))
        |> Map.put(:else, build_conditional_schema(else_schema))

      # if with then only
      not is_nil(then_schema) ->
        spec
        |> Map.put(:if, build_conditional_schema(if_schema))
        |> Map.put(:then, build_conditional_schema(then_schema))

      # if with else only
      not is_nil(else_schema) ->
        spec
        |> Map.put(:if, build_conditional_schema(if_schema))
        |> Map.put(:else, build_conditional_schema(else_schema))

      # if without then/else (just validation)
      true ->
        spec
        |> Map.put(:if, build_conditional_schema(if_schema))
    end
  end

  # Build a schema for conditionals (similar to composition but for if/then/else)
  defp build_conditional_schema(schema_module) when is_atom(schema_module) do
    if schema_module?(schema_module) do
      inline_nested_schema(schema_module)
    else
      raise ArgumentError,
            "Module #{inspect(schema_module)} is not a valid schema in conditional"
    end
  end

  defp build_conditional_schema(schema_spec) when is_map(schema_spec) do
    # Allow inline schema specifications
    schema_spec
  end

  defp build_conditional_schema(invalid) do
    raise ArgumentError,
          "Invalid conditional schema: #{inspect(invalid)}. Expected a schema module or map."
  end

  # Default value
  defp add_default_value(spec, opts) do
    # Use Keyword.has_key? to distinguish between no default and default: nil
    if Keyword.has_key?(opts, :default) do
      Map.put(spec, :default, opts[:default])
    else
      spec
    end
  end

  # Examples
  defp add_examples(spec, opts) do
    maybe_put(spec, :examples, opts[:examples])
  end

  # Helper to conditionally add keys to map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Helper to inline a nested schema's specification
  defp inline_nested_schema(schema_module) when is_atom(schema_module) do
    if function_exported?(schema_module, :__schema__, 1) do
      spec = schema_module.__schema__(:specification)
      # Return the relevant parts for inlining (exclude top-level metadata like title, $schema)
      Map.take(spec, [:type, :properties, :required, :description])
    else
      raise ArgumentError, "Module #{inspect(schema_module)} is not a valid schema"
    end
  end

  # Check if a type is a schema module
  defp schema_module?(type) when is_atom(type) do
    Code.ensure_compiled(type) == {:module, type} and
      function_exported?(type, :__schema__, 1)
  end

  defp check_field_type!(_mod, name, :datetime, _opts) do
    raise ArgumentError,
          "invalid type :datetime for field #{inspect(name)}. " <>
            "You probably meant to choose one between :naive_datetime " <>
            "(no time zone information) or :utc_datetime (time zone is set to UTC)"
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp check_field_type!(mod, name, type, opts) do
    cond do
      composite?(type, name) ->
        {outer_type, inner_type} = type
        {outer_type, check_field_type!(mod, name, inner_type, opts)}

      not is_atom(type) ->
        raise ArgumentError,
              "invalid type #{Normandy.Type.format(type)} for field #{inspect(name)}"

      Normandy.Type.base?(type) ->
        type

      Code.ensure_compiled(type) == {:module, type} ->
        cond do
          function_exported?(type, :type, 0) ->
            type

          function_exported?(type, :type, 1) ->
            Normandy.ParameterizedType.init(
              type,
              Keyword.merge(opts, field: name, schema: mod)
            )

          function_exported?(type, :__schema__, 1) ->
            # Schema module - valid as a nested schema type
            type

          true ->
            raise ArgumentError,
                  "module #{inspect(type)} given as type for field #{inspect(name)} is not an Normandy.Type/Normandy.ParameterizedType"
        end

      true ->
        raise ArgumentError, "unknown type #{inspect(type)} for field #{inspect(name)}"
    end
  end

  defp composite?({composite, _} = type, name) do
    if Normandy.Type.composite?(composite) do
      true
    else
      raise ArgumentError,
            "invalid or unknown composite #{inspect(type)} for field #{inspect(name)}. " <>
              "Did you mean to use :array or :map as first element of the tuple instead?"
    end
  end

  defp composite?(_type, _name), do: false

  defp check_options!(opts, valid, fun_arity) do
    case Enum.find(opts, fn {k, _} -> k not in valid end) do
      {k, _} -> raise ArgumentError, "invalid option #{inspect(k)} for #{fun_arity}"
      nil -> :ok
    end
  end

  # Value checks for the options Normandy reads, so a wrong type fails the
  # schema's compilation instead of making every validation fail (or pass).
  @option_kinds [
    min_length: :non_neg_integer,
    max_length: :non_neg_integer,
    min_items: :non_neg_integer,
    max_items: :non_neg_integer,
    minimum: :number,
    maximum: :number,
    exclusive_minimum: :number,
    exclusive_maximum: :number,
    pattern: :regex,
    format: :string,
    description: :string,
    enum: :list,
    examples: :list,
    any_of: :list,
    one_of: :list,
    all_of: :list,
    required: :boolean,
    redact: :boolean,
    virtual: :boolean,
    unique_items: :boolean,
    include_in_json_schema: :boolean,
    skip_default_validation: :boolean
  ]

  defp check_option_values!(name, opts) do
    for {key, kind} <- @option_kinds, Keyword.has_key?(opts, key) do
      check_option_value!(name, key, kind, Keyword.fetch!(opts, key))
    end

    :ok
  end

  defp check_option_value!(name, :pattern, :regex, value) when is_binary(value) do
    case Regex.compile(value) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "field/3: option :pattern for field #{inspect(name)} is not a valid regex " <>
                "(#{inspect(reason)}): #{inspect(value)}"
    end
  end

  defp check_option_value!(name, key, kind, value) do
    unless option_kind?(kind, value) do
      raise ArgumentError,
            "field/3: option #{inspect(key)} for field #{inspect(name)} must be " <>
              "#{option_kind_text(kind)}, got: #{inspect(value)}"
    end
  end

  defp option_kind?(:non_neg_integer, value), do: is_integer(value) and value >= 0
  defp option_kind?(:number, value), do: is_number(value)
  defp option_kind?(:string, value), do: is_binary(value)
  defp option_kind?(:list, value), do: is_list(value)
  defp option_kind?(:boolean, value), do: is_boolean(value)
  defp option_kind?(:regex, _value), do: false

  defp option_kind_text(:non_neg_integer), do: "a non-negative integer"
  defp option_kind_text(:number), do: "a number"
  defp option_kind_text(:string), do: "a string"
  defp option_kind_text(:list), do: "a list"
  defp option_kind_text(:boolean), do: "a boolean"
  defp option_kind_text(:regex), do: "a regex string (JSON Schema patterns are strings)"

  defp check_options!({:parameterized, _}, _opts, _valid, _fun_arity) do
    :ok
  end

  defp check_options!({_, type}, opts, valid, fun_arity) do
    check_options!(type, opts, valid, fun_arity)
  end

  defp check_options!(_type, opts, valid, fun_arity) do
    check_options!(opts, valid, fun_arity)
  end

  defp validate_default!(_type, _value, true), do: :ok

  defp validate_default!(type, value, _skip) do
    case Normandy.Type.dump(type, value) do
      {:ok, _} ->
        :ok

      _ ->
        raise ArgumentError,
              "value #{inspect(value)} is invalid for type #{Normandy.Type.format(type)}, can't set default"
    end
  end

  defp define_field(mod, name, type, opts) do
    is_virtual = Keyword.get(opts, :virtual, false)
    compute_fn = Keyword.get(opts, :compute)

    # Virtual fields still need to be in the struct
    put_struct_field(mod, name, Keyword.get(opts, :default))

    if Keyword.get(opts, :redact, false) do
      Module.put_attribute(mod, :schema_redact_fields, name)
    end

    description = Keyword.get(opts, :description, "")

    # Virtual fields cannot be required
    if Keyword.get(opts, :required, false) and is_virtual do
      raise ArgumentError,
            "virtual field `#{name}` cannot be required. " <>
              "Virtual fields are computed and not part of the input data."
    end

    if Keyword.get(opts, :required, false) do
      Module.put_attribute(mod, :schema_required_fields, name)
    end

    # Track virtual fields separately
    if is_virtual do
      Module.put_attribute(mod, :schema_virtual_fields, name)

      # Track computed fields with their computation function
      if compute_fn do
        Module.put_attribute(mod, :schema_computed_fields, {name, compute_fn})
      end
    end

    # Store type, description, and all opts for JSON schema generation
    Module.put_attribute(mod, :schema_fields, {name, {type, description, opts}})
  end

  defp put_struct_field(mod, name, assoc) do
    fields = Module.get_attribute(mod, :schema_struct_fields)

    if List.keyfind(fields, name, 0) do
      raise ArgumentError,
            "field/association #{inspect(name)} already exists on schema, you must either remove the duplication or choose a different name"
    end

    Module.put_attribute(mod, :schema_struct_fields, {name, assoc})
  end
end
