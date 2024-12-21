defmodule Normandy.Tools.Schema do

  alias Normandy.Tools.Metadata
  @field_opts [
    :default,
    :source,
    :autogenerate,
    :read_after_writes,
    :virtual,
    :primary_key,
    :load_in_query,
    :redact,
    :foreign_key,
    :on_replace,
    :defaults,
    :type,
    :where,
    :references,
    :skip_default_validation,
    :writable
  ]

  @doc false
  defmacro __using__(_) do
    quote do
      import Normandy.Tools.Schema, only: [schema: 1]

      Module.register_attribute(__MODULE__, :tool_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :tool_raw, accumulate: true)
      Module.register_attribute(__MODULE__, :tool_redact_fields, accumulate: true)
    end
  end

  defmacro schema(do: block) do
    prelude =
      quote do
        Normandy.Tools.Schema.__schema__(__MODULE__, __ENV__.line)
        try do
          import Normandy.Tools.Schema
          unquote(block)
        after
          :ok
        end
      end
    postlude =
      quote unquote: false do
        {struct_fields, bags_of_clauses} = Normandy.Tools.Schema.__schema__(__MODULE__)
        defstruct struct_fields

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

 defmacro field(name, type \\ :string, opts \\ []) do
    quote do
      Normandy.Tools.Schema.__field__(__MODULE__, unquote(name), unquote(type), unquote(opts))
    end
  end

  @doc false
  def __field__(mod, name, type, opts) do
    # Check the field type before we check options because it is
    # better to raise unknown type first than unsupported option.
    type = check_field_type!(mod, name, type, opts)

    check_options!(type, opts, @field_opts, "field/3")
    Module.put_attribute(mod, :tool_changeset_fields, {name, type})
    validate_default!(type, opts[:default], opts[:skip_default_validation])
    define_field(mod, name, type, opts)
  end

    @doc false
  def __schema__(module, line) do
    if previous_line = Module.get_attribute(module, :tool_schema_defined) do
      raise "schema already defined for #{inspect(module)} on line #{previous_line}"
    end

    Module.put_attribute(module, :tool_schema_defined, line)

    if Code.can_await_module_compilation?() do
      Module.put_attribute(module, :after_verify, Normandy.Tools.Schema)
    end

    Module.register_attribute(module, :tool_struct_fields, accumulate: true)

    context = Module.get_attribute(module, :schema_context)

    meta = %Metadata{
      state: :built,
      context: context,
      schema: module
    }

    Module.put_attribute(module, :tool_struct_fields, {:__meta__, meta})
  end

  @doc false
  def __schema__(module) do
    fields = Module.get_attribute(module, :tool_fields) |> Enum.reverse()
    struct_fields = Module.get_attribute(module, :tool_struct_fields) |> Enum.reverse()
    redacted_fields = Module.get_attribute(module, :tool_redact_fields)
    derive = Module.get_attribute(module, :derive)

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
      for {name, {type, writable}} <- fields do
        {name, { name, type, writable}}
      end

    field_sources_quoted =
      for {name, {_type, _writable}} <- fields do
        {[:field_source, name], name}
      end

    types_quoted =
      for {name, {type, _writable}} <- fields do
        {[:type, name], Macro.escape(type)}
      end

   single_arg = [
      {[:dump], dump |> Map.new() |> Macro.escape()},
      {[:redact_fields], redacted_fields},
      {[:fields], Enum.map(fields, &elem(&1, 0))},
      {[:loaded], Macro.escape(loaded)}
    ]

    catch_all = [
      {[:type, quote(do: _)], nil},
    ]

    bags_of_clauses =
      [
        single_arg,
        field_sources_quoted,
        types_quoted,
        catch_all
      ]

    {struct_fields, bags_of_clauses}
  end

  defp derive_inspect?(module) do
    Module.get_attribute(module, :derive_inspect_for_redacted_fields, true)
  end
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
        raise ArgumentError, "invalid type #{Normandy.Tools.Type.format(type)} for field #{inspect(name)}"

      Normandy.Tools.Type.base?(type) ->
        type

      Code.ensure_compiled(type) == {:module, type} ->
        cond do
          function_exported?(type, :type, 0) ->
            type

          function_exported?(type, :type, 1) ->
            Normandy.Tools.ParameterizedType.init(type, Keyword.merge(opts, field: name, schema: mod))

          function_exported?(type, :__schema__, 1) ->
            raise ArgumentError,
                  "schema #{inspect(type)} is not a valid type for field #{inspect(name)}." <>
                    " Did you mean to use belongs_to, has_one, has_many, embeds_one, or embeds_many instead?"

          true ->
            raise ArgumentError,
                  "module #{inspect(type)} given as type for field #{inspect(name)} is not an Normandy.Tools.Type/Normandy.Tools.ParameterizedType"
        end

      true ->
        raise ArgumentError, "unknown type #{inspect(type)} for field #{inspect(name)}"
    end
  end
  defp composite?({composite, _} = type, name) do
    if Normandy.Tools.Type.composite?(composite) do
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
    case Normandy.Tools.Type.dump(type, value) do
      {:ok, _} ->
        :ok

      _ ->
        raise ArgumentError,
              "value #{inspect(value)} is invalid for type #{Normandy.Tools.Type.format(type)}, can't set default"
    end
  end

  defp define_field(mod, name, type, opts) do
    put_struct_field(mod, name, Keyword.get(opts, :default))

    if Keyword.get(opts, :redact, false) do
      Module.put_attribute(mod, :tool_redact_fields, name)
    end

    Module.put_attribute(mod, :tool_fields, {name, {type}})
  end

  defp put_struct_field(mod, name, assoc) do
    fields = Module.get_attribute(mod, :tool_struct_fields)
    if List.keyfind(fields, name, 0) do
      raise ArgumentError,
            "field/association #{inspect(name)} already exists on schema, you must either remove the duplication or choose a different name"
    end

    Module.put_attribute(mod, :tool_struct_fields, {name, assoc})
  end
end
