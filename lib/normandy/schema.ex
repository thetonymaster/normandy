defmodule Normandy.Schema do
  @moduledoc """
  Provides a macro-based DSL for defining structured data schemas.

  This module allows you to define structs with typed fields, default values,
  validation rules, and metadata. It's the foundation for defining agents,
  messages, and other structured data in Normandy.

  ## Features

  - Type-safe field definitions
  - Default value support
  - Field-level validation
  - Automatic struct generation
  - Metadata tracking
  - Field redaction support

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
  """

  alias Normandy.Metadata

  @field_opts [
    :default,
    :redact,
    :defaults,
    :type,
    :where,
    :references,
    :skip_default_validation,
    :description,
    :required
  ]

  @type schema :: %{optional(atom) => any, __struct__: atom, __meta__: Metadata.t()}
  @type t :: schema

  @doc false
  defmacro __using__(_) do
    quote do
      import Normandy.Schema, only: [schema: 1, io_schema: 2]

      Module.register_attribute(__MODULE__, :schema_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_raw, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_redact_fields, accumulate: true)
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
            @adapter Application.compile_env(:normandy, :adapter)
            def __str__(str), do: @adapter.encode!(str)
            def __rich__(str), do: @adapter.encode!(str, pretty: true)
            def to_json(str), do: @adapter.encode!(str)
            def get_schema(str), do: str.__struct__.get_json_schema()
          end

          def get_json_schema() do
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
  def __schema__(module) do
    fields = Module.get_attribute(module, :schema_fields) |> Enum.reverse()
    struct_fields = Module.get_attribute(module, :schema_struct_fields) |> Enum.reverse()
    redacted_fields = Module.get_attribute(module, :schema_redact_fields)
    derive = Module.get_attribute(module, :derive)
    required_fields = Module.get_attribute(module, :schema_required_fields, []) |> Enum.reverse()
    description = Module.get_attribute(module, :description, nil)

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
      for {name, {type, _description}} <- fields do
        {name, {name, type}}
      end

    types_quoted =
      for {name, {type, _description}} <- fields do
        {[:type, name], Macro.escape(type)}
      end

    specification = %{
      title: module |> to_string() |> String.split(".") |> List.last(),
      type: "object",
      "$schema": "https://json-schema.org/draft/2020-12/schema"
    }

    specification =
      if description != nil do
        Map.put(specification, :description, description)
      else
        specification
      end

    properties =
      for {name, opts} <- fields do
        check_specification_type(name, opts)
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
      {[:specification], Macro.escape(specification)}
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

  defp check_specification_type(name, {{:array, type}, description}) do
    {name, %{type: :array, description: description, items: %{type: type}}}
  end

  defp check_specification_type(name, {{:map, _type}, description}) do
    {name, %{type: :object, description: description}}
  end

  defp check_specification_type(name, {:float, description}),
    do: {name, %{type: :number, description: description}}

  defp check_specification_type(name, {type, description}),
    do: {name, %{type: type, description: description}}

  defp check_field_type!(_mod, name, :datetime, _opts) do
    raise ArgumentError,
          "invalid type :datetime for field #{inspect(name)}. " <>
            "You probably meant to choose one between :naive_datetime " <>
            "(no time zone information) or :utc_datetime (time zone is set to UTC)"
  end

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
            raise ArgumentError,
                  "schema #{inspect(type)} is not a valid type for field #{inspect(name)}." <>
                    " Did you mean to use belongs_to, has_one, has_many, embeds_one, or embeds_many instead?"

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
    put_struct_field(mod, name, Keyword.get(opts, :default))

    if Keyword.get(opts, :redact, false) do
      Module.put_attribute(mod, :schema_redact_fields, name)
    end

    description = Keyword.get(opts, :description, "")

    if Keyword.get(opts, :required, false) do
      Module.put_attribute(mod, :schema_required_fields, name)
    end

    Module.put_attribute(mod, :schema_fields, {name, {type, description}})
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
