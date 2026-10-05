defmodule Normandy.Tools.Input do
  @moduledoc """
  Validates a tool call's input before the tool runs.

  The dispatcher checks the model's input here and passes the result to
  `c:Normandy.Tool.run/2` as `context.input`; it never goes into the tool struct.

    * A tool that declared `input: Schema` (`use Normandy.Tool`) gets a `%Schema{}`. Every key
      (string or atom) must name a field of the schema; the values are checked by
      `Normandy.Schema.Validator` (types, required fields, enums, ranges, formats; nothing is
      coerced, so `"5"` for an integer field is an error); missing optional fields take their
      defaults.
    * Any other tool gets a string-keyed map checked against its `c:Normandy.Tool.input_schema/1`
      map (string or atom keys): every `required` key present, each value's basic JSON type
      (`string`, `integer`, `number`, `boolean`, `object`, `array`, `null`) where its property
      declares one, and unknown keys as follows. A schema that declares `properties` is
      closed: no key outside them unless `additionalProperties` is `true` or a schema (an
      absent `additionalProperties` counts as `false` here, unlike JSON Schema's default). A
      schema with no `properties` key declares no keys, so it limits none: any key is
      accepted (an MCP server's loose `{"type": "object"}` keeps working). Nested schemas,
      enums and formats are the tool's to check. A `type` name outside the seven above (a
      typo such as `"intger"`) is not checked: any value passes it. An `input_schema/1` that
      returns something other than a map, or a map whose `properties` is not a map or whose
      `required` is not a list of key names, is an error (`constraint: :schema`).

  An unknown key is an error for a declared input schema and for a map that declares
  `properties`, and keys are matched against declared names, so model input never creates an
  atom. A key that is neither a string nor an atom is always an unknown key, named by its type
  (`"a tuple key"`). Errors are `%{path: [key], message: String.t(),
  constraint: atom()}`; `message/1` joins them into one line for the model.
  """

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Schema.Validator

  @type error :: %{path: [atom() | String.t()], message: String.t(), constraint: atom()}

  @doc "Validates `input` against `tool`'s input schema; see the moduledoc."
  @spec validate(struct(), term()) :: {:ok, struct() | map()} | {:error, [error()]}
  def validate(%module{} = tool, input) when is_map(input) and not is_struct(input) do
    # The callback's spec says map(), but input_schema/1 is the tool's code (an MCP tool
    # returns its server's schema, nil when the server sent none), so its result is
    # checked here, not trusted: hence the module call rather than Normandy.Tool's.
    if Code.ensure_loaded?(module) and function_exported?(module, :__tool_input__, 0),
      do: validate_schema(module.__tool_input__(), input),
      else: validate_map(module.input_schema(tool), input)
  end

  def validate(_tool, input) do
    {:error,
     [
       %{
         path: [],
         message: "expected a JSON object, got: #{Describe.type_of(input)}",
         constraint: :type
       }
     ]}
  end

  @doc ~S"""
  One line for the model: errors joined by `"; "`, each as `"<path> <message>"` (a
  path-less error is its message alone).

      iex> Normandy.Tools.Input.message([%{path: [:query], message: "is required", constraint: :required}])
      "query is required"
  """
  @spec message([error()]) :: String.t()
  def message(errors) when is_list(errors) do
    Enum.map_join(errors, "; ", fn
      %{path: [], message: message} -> message
      %{path: path, message: message} -> Enum.map_join(path, ".", &to_string/1) <> " " <> message
    end)
  end

  defp validate_schema(schema, input) do
    fields = schema.__schema__(:fields)
    by_name = Map.new(fields, &{Atom.to_string(&1), &1})
    {known, unknown, repeated} = split_keys(input, by_name)

    errors =
      unknown_keys(Enum.uniq(unknown), Enum.map(fields, &Atom.to_string/1)) ++
        repeated_keys(repeated) ++ sort_by_path(schema_errors(Validator.validate(schema, known)))

    case errors do
      [] -> {:ok, struct(schema, known)}
      errors -> {:error, errors}
    end
  end

  # A key maps to a field through the declared names; String.to_atom/1 is never called on it.
  defp split_keys(input, by_name) do
    Enum.reduce(input, {%{}, [], []}, fn {key, value}, {known, unknown, repeated} ->
      name = key_name(key)

      case field(key, name, by_name) do
        {:ok, field} when is_map_key(known, field) -> {known, unknown, [name | repeated]}
        {:ok, field} -> {Map.put(known, field, value), unknown, repeated}
        :error -> {known, [name | unknown], repeated}
      end
    end)
  end

  # A key that is neither a string nor an atom names no field (its name is a type label).
  defp field(key, name, by_name) when is_binary(key) or is_atom(key), do: Map.fetch(by_name, name)
  defp field(_key, _name, _by_name), do: :error

  defp schema_errors({:ok, _data}), do: []
  defp schema_errors({:error, errors}), do: errors

  defp validate_map(schema, input) when is_map(schema) do
    with {:ok, properties} <- schema_properties(schema),
         {:ok, required} <- schema_required(schema) do
      validate_map(schema, properties, required, input)
    end
  end

  # No silent default: a tool whose input_schema/1 is not a map (an MCP tool whose server
  # sent none) gets an error result naming what it returned.
  defp validate_map(schema, _input) do
    schema_error(
      "the tool's input_schema/1 returned #{Describe.type_of(schema)}, not a JSON Schema map"
    )
  end

  defp validate_map(schema, properties, required, input) do
    # No `properties` key: the schema names no keys, so it limits none (decision 18). With
    # `properties`, an absent `additionalProperties` closes it.
    open? =
      not has?(schema, :properties) or
        get(schema, :additionalProperties, false) not in [false, nil]

    {given, repeated, unnamed} = string_keys(input)

    # A key that is neither a string nor an atom names nothing a schema can declare, so it
    # is refused even by an open schema.
    unknown = if open?, do: unnamed, else: unnamed ++ (Map.keys(given) -- Map.keys(properties))
    missing = Enum.sort(required -- Map.keys(given))

    errors =
      unknown_keys(Enum.uniq(unknown), properties |> Map.keys() |> Enum.sort()) ++
        repeated_keys(repeated) ++
        Enum.map(missing, &%{path: [&1], message: "is required", constraint: :required}) ++
        sort_by_path(type_errors(given, properties))

    case errors do
      [] -> {:ok, given}
      errors -> {:error, errors}
    end
  end

  defp schema_properties(schema) do
    case get(schema, :properties, %{}) do
      %{} = properties ->
        {:ok, Map.new(properties, fn {k, v} -> {to_string(k), v} end)}

      other ->
        schema_error(
          ~s(the tool's input_schema/1 "properties" is #{Describe.type_of(other)}, not a map)
        )
    end
  end

  defp schema_required(schema) do
    required = get(schema, :required, [])

    if is_list(required) and Enum.all?(required, &(is_binary(&1) or is_atom(&1))) do
      {:ok, Enum.map(required, &to_string/1)}
    else
      schema_error(
        ~s(the tool's input_schema/1 "required" is #{Describe.type_of(required)}, ) <>
          "not a list of key names"
      )
    end
  end

  defp schema_error(message), do: {:error, [%{path: [], message: message, constraint: :schema}]}

  defp string_keys(input) do
    Enum.reduce(input, {%{}, [], []}, fn {key, value}, {given, repeated, unnamed} ->
      name = key_name(key)

      cond do
        not (is_binary(key) or is_atom(key)) -> {given, repeated, [name | unnamed]}
        Map.has_key?(given, name) -> {given, [name | repeated], unnamed}
        true -> {Map.put(given, name, value), repeated, unnamed}
      end
    end)
  end

  defp type_errors(given, properties) do
    Enum.flat_map(given, fn {name, value} ->
      with %{} = spec <- Map.get(properties, name),
           type when not is_nil(type) <- get(spec, :type, nil),
           false <- json_type?(value, type) do
        [
          %{
            path: [name],
            message: "expected type #{type_label(type)}, got #{json_type(value)}",
            constraint: :type
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp unknown_keys([], _expected), do: []

  defp unknown_keys(unknown, expected) do
    noun = if length(unknown) == 1, do: "unknown key", else: "unknown keys"
    expected = if expected == [], do: "no keys", else: "only " <> quote_list(expected)

    [
      %{
        path: [],
        message: "#{noun} #{quote_list(Enum.sort(unknown))}; expected #{expected}",
        constraint: :unknown_keys
      }
    ]
  end

  defp repeated_keys(repeated) do
    for name <- Enum.sort(repeated) do
      %{
        path: [name],
        message: "is given twice (as a string key and as an atom key)",
        constraint: :duplicate_key
      }
    end
  end

  defp sort_by_path(errors),
    do: Enum.sort_by(errors, &Enum.map(&1.path, fn p -> to_string(p) end))

  defp quote_list(names), do: Enum.map_join(names, ", ", &inspect/1)

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  # Described by its type: the key's terms are the model's or a hook's, not for the message.
  defp key_name(key), do: Describe.type_of(key) <> " key"

  # A schema map may use atom or string keys (built-in tools use both).
  defp get(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp has?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp json_type?(value, types) when is_list(types), do: Enum.any?(types, &json_type?(value, &1))
  defp json_type?(value, type) when is_atom(type), do: json_type?(value, Atom.to_string(type))
  defp json_type?(value, "string"), do: is_binary(value)
  defp json_type?(value, "integer"), do: is_integer(value)
  defp json_type?(value, "number"), do: is_number(value)
  defp json_type?(value, "boolean"), do: is_boolean(value)
  defp json_type?(value, "object"), do: is_map(value)
  defp json_type?(value, "array"), do: is_list(value)
  defp json_type?(value, "null"), do: is_nil(value)
  # A type name outside JSON Schema's basic seven is not this module's to check.
  defp json_type?(_value, _type), do: true

  defp type_label(types) when is_list(types), do: Enum.map_join(types, " or ", &to_string/1)
  defp type_label(type), do: to_string(type)

  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_integer(value), do: "integer"
  defp json_type(value) when is_float(value), do: "number"
  defp json_type(value) when is_boolean(value), do: "boolean"
  defp json_type(nil), do: "null"
  defp json_type(value) when is_list(value), do: "array"
  defp json_type(value) when is_map(value), do: "object"
  defp json_type(_value), do: "an unsupported term"
end
