defmodule Normandy.Schema.Validator do
  @moduledoc """
  Runtime validation of data against Normandy schemas.

  This module provides functions to validate arbitrary data against
  Normandy schema specifications, ensuring data conforms to the
  defined JSON Schema constraints.

  ## Examples

      defmodule UserSchema do
        use Normandy.Schema

        schema do
          field :name, :string, required: true, min_length: 1
          field :age, :integer, minimum: 0, maximum: 150
          field :email, :string, format: "email"
        end
      end

      # Valid data
      {:ok, _} = Normandy.Schema.Validator.validate(
        UserSchema,
        %{name: "Alice", age: 30, email: "alice@example.com"}
      )

      # Invalid data
      {:error, errors} = Normandy.Schema.Validator.validate(
        UserSchema,
        %{age: -5}
      )

  ## Validation Features

  This validator supports the following JSON Schema validations:

  - **Type validation** - Ensures values match their declared types
    (`:date`, `:time` and `:duration` fields are JSON strings with a `format`;
    the matching `Date`, `Time` or `Duration` value is accepted too)
  - **Required fields** - Validates required fields are present
  - **String constraints**
    - `minLength` / `min_length` - Minimum string length
    - `maxLength` / `max_length` - Maximum string length
    - `pattern` - Regular expression pattern matching
    - `format` - String format validation (email, uri, uuid, date-time, ipv4, ipv6)
  - **Number constraints**
    - `minimum` - Minimum value (inclusive)
    - `maximum` - Maximum value (inclusive)
    - `exclusiveMinimum` - Minimum value (exclusive)
    - `exclusiveMaximum` - Maximum value (exclusive)
    - `multipleOf` / `multiple_of` - Value must be a multiple of the number
  - **Array constraints**
    - `minItems` / `min_items` - Minimum array length
    - `maxItems` / `max_items` - Maximum array length
    - `uniqueItems` / `unique_items` - Ensures array items are unique
  - **Object constraints**
    - `additionalProperties` - `false` rejects keys outside `properties`; a
      schema checks their values (a `{:map, inner}` field emits this)
    - `patternProperties` - Checks the values of keys matching a regex
  - **Enum validation** - Ensures values are in allowed list
  - **`const`** - Value must equal the given value
  - **Composition** - anyOf, oneOf, allOf for complex type unions and intersections
  - **`not`** - Value must not match the schema
  - **Conditionals** - if/then/else schemas for context-dependent validation
  - **Nested schemas** - Validates nested objects and arrays recursively

  Every keyword applies at every level: the root, each field, array items, and
  each composition or conditional sub-schema.

  ### Format Validation

  The validator supports the following string formats:

  - `email` - RFC 5322 email addresses (simplified)
  - `uri` - Uniform Resource Identifiers
  - `uuid` - UUID (Universally Unique Identifier) format
  - `date-time` - ISO 8601 date-time format
  - `ipv4` - IPv4 address format
  - `ipv6` - IPv6 address format (simplified)

  ## Error Format

  Validation errors are returned as a list of maps with the following structure:

      %{
        path: [:field, :nested_field],  # Path to the invalid field
        message: "error message",        # Human-readable error message
        constraint: :minimum             # The constraint that failed
      }
  """

  @doc """
  Validates data against a Normandy schema module.

  Returns `{:ok, data}` if validation succeeds, or `{:error, errors}` if
  validation fails.

  ## Examples

      validate(MySchema, %{name: "Alice"})
      #=> {:ok, %{name: "Alice"}}

      validate(MySchema, %{age: -1})
      #=> {:error, [%{path: [:age], message: "must be >= 0", constraint: :minimum}]}
  """
  def validate(schema_module, data) when is_atom(schema_module) do
    spec = schema_module.__schema__(:specification)
    validate_against_spec(data, spec, [])
  end

  @doc """
  Validates data against a Normandy schema module, raising on error.

  Returns the data if validation succeeds, or raises a `Normandy.Schema.ValidationError`
  if validation fails.

  ## Examples

      validate!(MySchema, %{name: "Alice"})
      #=> %{name: "Alice"}

      validate!(MySchema, %{age: -1})
      #=> ** (Normandy.Schema.ValidationError) Validation failed: age must be >= 0
  """
  def validate!(schema_module, data) do
    case validate(schema_module, data) do
      {:ok, data} ->
        data

      {:error, errors} ->
        raise Normandy.Schema.ValidationError,
          message: format_errors(errors),
          errors: errors
    end
  end

  # Validate data against a schema specification
  defp validate_against_spec(data, spec, path) do
    case validate_schema([], data, spec, path) do
      [] -> {:ok, data}
      errors -> {:error, errors}
    end
  end

  # Every keyword, at every level: the root spec, a field's spec, an array's
  # items, and each composition or conditional sub-schema. A keyword that does
  # not apply to the value's type is skipped.
  defp validate_schema(errors, data, spec, path) do
    errors
    |> validate_type(data, spec, path)
    |> validate_const(data, spec, path)
    |> validate_enum(data, spec, path)
    |> validate_string_constraints(data, spec, path)
    |> validate_number_constraints(data, spec, path)
    |> validate_array_constraints(data, spec, path)
    |> validate_required_fields(data, spec, path)
    |> validate_properties(data, spec, path)
    |> validate_other_properties(data, spec, path)
    |> validate_composition(data, spec, path)
    |> validate_not(data, spec, path)
    |> validate_conditionals(data, spec, path)
  end

  # Type validation
  defp validate_type(errors, data, spec, path) do
    type = spec[:type]

    cond do
      is_nil(type) ->
        errors

      valid_type?(data, type) or formatted_value?(data, type, spec[:format]) ->
        errors

      true ->
        [
          %{
            path: path,
            message: "expected type #{type}, got #{actual_type(data)}",
            constraint: :type
          }
          | errors
        ]
    end
  end

  defp valid_type?(_data, :any), do: true
  defp valid_type?(data, :string) when is_binary(data), do: true
  defp valid_type?(data, :integer) when is_integer(data), do: true
  defp valid_type?(data, :number) when is_number(data), do: true
  defp valid_type?(data, :float) when is_float(data), do: true
  defp valid_type?(data, :boolean) when is_boolean(data), do: true
  defp valid_type?(data, :map) when is_map(data), do: true
  defp valid_type?(data, :object) when is_map(data), do: true
  defp valid_type?(data, :array) when is_list(data), do: true
  defp valid_type?(%Date{}, :date), do: true
  defp valid_type?(%Time{}, :time), do: true
  defp valid_type?(%NaiveDateTime{}, :naive_datetime), do: true
  defp valid_type?(%DateTime{}, :datetime), do: true
  defp valid_type?(_, _), do: false

  # `:date`, `:time` and `:duration` fields are JSON strings with a format; the
  # data may hold the Elixir value itself rather than its string form.
  defp formatted_value?(%Date{}, :string, "date"), do: true
  defp formatted_value?(%Time{}, :string, "time"), do: true

  # Duration ships with Elixir 1.17; on 1.15 and 1.16 the struct pattern would not compile.
  if Code.ensure_loaded?(Duration) do
    defp formatted_value?(%Duration{}, :string, "duration"), do: true
  end

  defp formatted_value?(_, _, _), do: false

  defp actual_type(data) when is_binary(data), do: :string
  defp actual_type(data) when is_integer(data), do: :integer
  defp actual_type(data) when is_float(data), do: :float
  defp actual_type(data) when is_boolean(data), do: :boolean
  defp actual_type(data) when is_list(data), do: :array
  defp actual_type(data) when is_map(data), do: :object
  defp actual_type(%Date{}), do: :date
  defp actual_type(%Time{}), do: :time
  defp actual_type(%NaiveDateTime{}), do: :naive_datetime
  defp actual_type(%DateTime{}), do: :datetime
  defp actual_type(_), do: :unknown

  # Required fields validation
  defp validate_required_fields(errors, data, spec, path) when is_map(data) do
    required = spec[:required] || []

    Enum.reduce(required, errors, fn field, acc ->
      if Map.has_key?(data, field) do
        acc
      else
        [
          %{
            path: path ++ [field],
            message: "is required",
            constraint: :required
          }
          | acc
        ]
      end
    end)
  end

  defp validate_required_fields(errors, _data, _spec, _path), do: errors

  # Properties validation
  defp validate_properties(errors, data, spec, path) when is_map(data) do
    properties = spec[:properties] || %{}

    Enum.reduce(properties, errors, fn {field, field_spec}, acc ->
      if Map.has_key?(data, field) do
        validate_schema(acc, Map.get(data, field), field_spec, path ++ [field])
      else
        acc
      end
    end)
  end

  defp validate_properties(errors, _data, _spec, _path), do: errors

  # Keys outside `properties`: a `patternProperties` entry whose regex matches
  # the key checks the value; any other key is checked against
  # `additionalProperties` (false rejects it, a schema checks the value).
  defp validate_other_properties(errors, data, spec, path) when is_map(data) do
    pattern_properties = spec[:patternProperties] || spec[:pattern_properties] || %{}
    additional = Map.get(spec, :additionalProperties, spec[:additional_properties])

    if pattern_properties == %{} and additional in [nil, true] do
      errors
    else
      properties = spec[:properties] || %{}

      data
      |> Map.drop([:__struct__, :__meta__ | Map.keys(properties)])
      |> Enum.reduce(errors, fn {key, value}, acc ->
        validate_other_property(acc, key, value, pattern_properties, additional, path ++ [key])
      end)
    end
  end

  defp validate_other_properties(errors, _data, _spec, _path), do: errors

  defp validate_other_property(errors, key, value, pattern_properties, additional, path) do
    case matching_pattern_schemas(pattern_properties, key) do
      [] -> validate_additional(errors, value, additional, path)
      schemas -> Enum.reduce(schemas, errors, &validate_schema(&2, value, &1, path))
    end
  end

  defp matching_pattern_schemas(pattern_properties, key) do
    for {pattern, schema} <- pattern_properties,
        Regex.match?(Regex.compile!(pattern), to_string(key)),
        do: schema
  end

  defp validate_additional(errors, _value, additional, _path) when additional in [nil, true],
    do: errors

  defp validate_additional(errors, _value, false, path) do
    [
      %{path: path, message: "is not an allowed property", constraint: :additional_properties}
      | errors
    ]
  end

  defp validate_additional(errors, value, schema, path) when is_map(schema),
    do: validate_schema(errors, value, schema, path)

  defp validate_const(errors, data, spec, path) do
    case Map.fetch(spec, :const) do
      {:ok, ^data} ->
        errors

      {:ok, expected} ->
        [%{path: path, message: "must be #{inspect(expected)}", constraint: :const} | errors]

      :error ->
        errors
    end
  end

  defp validate_not(errors, data, spec, path) do
    case spec[:not] do
      nil ->
        errors

      schema ->
        case validate_schema([], data, schema, path) do
          [] -> [%{path: path, message: "must not match the schema", constraint: :not} | errors]
          _ -> errors
        end
    end
  end

  # String constraints
  defp validate_string_constraints(errors, value, spec, path) when is_binary(value) do
    errors
    |> validate_min_length(value, spec, path)
    |> validate_max_length(value, spec, path)
    |> validate_pattern(value, spec, path)
    |> validate_format(value, spec, path)
  end

  defp validate_string_constraints(errors, _value, _spec, _path), do: errors

  defp validate_min_length(errors, value, spec, path) do
    # Check both camelCase (JSON Schema) and snake_case (Elixir) variants
    min_length = spec[:minLength] || spec[:min_length]

    case min_length do
      nil ->
        errors

      min_len ->
        if String.length(value) >= min_len do
          errors
        else
          [
            %{
              path: path,
              message: "must be at least #{min_len} characters",
              constraint: :min_length
            }
            | errors
          ]
        end
    end
  end

  defp validate_max_length(errors, value, spec, path) do
    # Check both camelCase (JSON Schema) and snake_case (Elixir) variants
    max_length = spec[:maxLength] || spec[:max_length]

    case max_length do
      nil ->
        errors

      max_len ->
        if String.length(value) <= max_len do
          errors
        else
          [
            %{
              path: path,
              message: "must be at most #{max_len} characters",
              constraint: :max_length
            }
            | errors
          ]
        end
    end
  end

  defp validate_pattern(errors, value, spec, path) do
    case spec[:pattern] do
      nil ->
        errors

      pattern ->
        regex = Regex.compile!(pattern)

        if Regex.match?(regex, value) do
          errors
        else
          [
            %{
              path: path,
              message: "must match pattern #{pattern}",
              constraint: :pattern
            }
            | errors
          ]
        end
    end
  end

  # A flat table, one clause per format.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_format(errors, value, spec, path) do
    case spec[:format] do
      nil -> errors
      "email" -> validate_email_format(errors, value, path)
      "uri" -> validate_uri_format(errors, value, path)
      "uuid" -> validate_uuid_format(errors, value, path)
      "date-time" -> validate_datetime_format(errors, value, path)
      "date" -> check_format(errors, path, "date", match?({:ok, _}, Date.from_iso8601(value)))
      "time" -> check_format(errors, path, "time", match?({:ok, _}, Time.from_iso8601(value)))
      "duration" -> check_format(errors, path, "duration", Regex.match?(duration_regex(), value))
      "hostname" -> check_format(errors, path, "hostname", Regex.match?(hostname_regex(), value))
      "ipv4" -> validate_ipv4_format(errors, value, path)
      "ipv6" -> validate_ipv6_format(errors, value, path)
      _ -> errors
    end
  end

  # Email format validation (RFC 5322 simplified)
  defp validate_email_format(errors, value, path) do
    email_regex =
      ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/

    if Regex.match?(email_regex, value) do
      errors
    else
      [
        %{
          path: path,
          message: "must be a valid email address",
          constraint: :format,
          format: "email"
        }
        | errors
      ]
    end
  end

  # URI format validation (simplified)
  defp validate_uri_format(errors, value, path) do
    uri_regex = ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:/

    if Regex.match?(uri_regex, value) do
      errors
    else
      [
        %{
          path: path,
          message: "must be a valid URI",
          constraint: :format,
          format: "uri"
        }
        | errors
      ]
    end
  end

  # UUID format validation
  defp validate_uuid_format(errors, value, path) do
    uuid_regex = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

    if Regex.match?(uuid_regex, value) do
      errors
    else
      [
        %{
          path: path,
          message: "must be a valid UUID",
          constraint: :format,
          format: "uuid"
        }
        | errors
      ]
    end
  end

  # ISO 8601 date-time format validation (simplified)
  # ISO 8601 durations (P1Y2M3W4DT5H6M7.5S; at least one part) and RFC 1123 hostnames.
  defp duration_regex,
    do: ~r/^P(?!$)(\d+Y)?(\d+M)?(\d+W)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+(\.\d+)?S)?)?$/

  defp hostname_regex,
    do:
      ~r/^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/

  defp check_format(errors, _path, _format, true), do: errors

  defp check_format(errors, path, format, false) do
    [
      %{path: path, message: "must be a valid #{format}", constraint: :format, format: format}
      | errors
    ]
  end

  defp validate_datetime_format(errors, value, path) do
    datetime_regex = ~r/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?$/

    if Regex.match?(datetime_regex, value) do
      errors
    else
      [
        %{
          path: path,
          message: "must be a valid ISO 8601 date-time",
          constraint: :format,
          format: "date-time"
        }
        | errors
      ]
    end
  end

  # IPv4 format validation
  defp validate_ipv4_format(errors, value, path) do
    ipv4_regex =
      ~r/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/

    if Regex.match?(ipv4_regex, value) do
      errors
    else
      [
        %{
          path: path,
          message: "must be a valid IPv4 address",
          constraint: :format,
          format: "ipv4"
        }
        | errors
      ]
    end
  end

  # IPv6 format validation (simplified)
  defp validate_ipv6_format(errors, value, path) do
    ipv6_regex =
      ~r/^(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$|^::(?:[0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{1,4}$|^[0-9a-fA-F]{1,4}::(?:[0-9a-fA-F]{1,4}:){0,5}[0-9a-fA-F]{1,4}$/

    if Regex.match?(ipv6_regex, value) do
      errors
    else
      [
        %{
          path: path,
          message: "must be a valid IPv6 address",
          constraint: :format,
          format: "ipv6"
        }
        | errors
      ]
    end
  end

  # Number constraints
  defp validate_number_constraints(errors, value, spec, path) when is_number(value) do
    errors
    |> validate_minimum(value, spec, path)
    |> validate_maximum(value, spec, path)
    |> validate_exclusive_minimum(value, spec, path)
    |> validate_exclusive_maximum(value, spec, path)
    |> validate_multiple_of(value, spec, path)
  end

  defp validate_number_constraints(errors, _value, _spec, _path), do: errors

  defp validate_multiple_of(errors, value, spec, path) do
    case spec[:multipleOf] || spec[:multiple_of] do
      nil ->
        errors

      factor ->
        if multiple_of?(value, factor) do
          errors
        else
          [
            %{path: path, message: "must be a multiple of #{factor}", constraint: :multiple_of}
            | errors
          ]
        end
    end
  end

  defp multiple_of?(value, factor) when is_integer(value) and is_integer(factor),
    do: rem(value, factor) == 0

  # Floats: 0.3 / 0.1 is 2.9999999999999996, so compare with a tolerance.
  defp multiple_of?(value, factor) do
    quotient = value / factor
    abs(quotient - round(quotient)) < 1.0e-9
  end

  defp validate_minimum(errors, value, spec, path) do
    case spec[:minimum] do
      nil ->
        errors

      minimum ->
        if value >= minimum do
          errors
        else
          [
            %{
              path: path,
              message: "must be >= #{minimum}",
              constraint: :minimum
            }
            | errors
          ]
        end
    end
  end

  defp validate_maximum(errors, value, spec, path) do
    case spec[:maximum] do
      nil ->
        errors

      maximum ->
        if value <= maximum do
          errors
        else
          [
            %{
              path: path,
              message: "must be <= #{maximum}",
              constraint: :maximum
            }
            | errors
          ]
        end
    end
  end

  defp validate_exclusive_minimum(errors, value, spec, path) do
    case spec[:exclusiveMinimum] do
      nil ->
        errors

      exclusive_minimum ->
        if value > exclusive_minimum do
          errors
        else
          [
            %{
              path: path,
              message: "must be > #{exclusive_minimum}",
              constraint: :exclusiveMinimum
            }
            | errors
          ]
        end
    end
  end

  defp validate_exclusive_maximum(errors, value, spec, path) do
    case spec[:exclusiveMaximum] do
      nil ->
        errors

      exclusive_maximum ->
        if value < exclusive_maximum do
          errors
        else
          [
            %{
              path: path,
              message: "must be < #{exclusive_maximum}",
              constraint: :exclusiveMaximum
            }
            | errors
          ]
        end
    end
  end

  # Array constraints
  defp validate_array_constraints(errors, value, spec, path) when is_list(value) do
    errors
    |> validate_min_items(value, spec, path)
    |> validate_max_items(value, spec, path)
    |> validate_unique_items(value, spec, path)
    |> validate_array_items(value, spec, path)
  end

  defp validate_array_constraints(errors, _value, _spec, _path), do: errors

  defp validate_min_items(errors, value, spec, path) do
    # Check both camelCase (JSON Schema) and snake_case (Elixir) variants
    min_items = spec[:minItems] || spec[:min_items]

    case min_items do
      nil ->
        errors

      min ->
        if length(value) >= min do
          errors
        else
          [
            %{
              path: path,
              message: "must have at least #{min} items",
              constraint: :min_items
            }
            | errors
          ]
        end
    end
  end

  defp validate_max_items(errors, value, spec, path) do
    # Check both camelCase (JSON Schema) and snake_case (Elixir) variants
    max_items = spec[:maxItems] || spec[:max_items]

    case max_items do
      nil ->
        errors

      max ->
        if length(value) <= max do
          errors
        else
          [
            %{
              path: path,
              message: "must have at most #{max} items",
              constraint: :max_items
            }
            | errors
          ]
        end
    end
  end

  defp validate_unique_items(errors, value, spec, path) do
    # Check both camelCase (JSON Schema) and snake_case (Elixir) variants
    unique = spec[:uniqueItems] || spec[:unique_items]

    case unique do
      true ->
        if length(value) == length(Enum.uniq(value)) do
          errors
        else
          [
            %{
              path: path,
              message: "must have unique items",
              constraint: :unique_items
            }
            | errors
          ]
        end

      _ ->
        errors
    end
  end

  defp validate_array_items(errors, value, spec, path) do
    case spec[:items] do
      nil ->
        errors

      items_spec ->
        value
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {item, index}, acc ->
          validate_schema(acc, item, items_spec, path ++ [index])
        end)
    end
  end

  # Enum validation
  defp validate_enum(errors, value, spec, path) do
    case spec[:enum] do
      nil ->
        errors

      enum_values ->
        if value in enum_values do
          errors
        else
          [
            %{
              path: path,
              message: "must be one of #{inspect(enum_values)}",
              constraint: :enum
            }
            | errors
          ]
        end
    end
  end

  # Composition validation (anyOf, oneOf, allOf)
  defp validate_composition(errors, data, spec, path) do
    errors
    |> validate_any_of(data, spec, path)
    |> validate_one_of(data, spec, path)
    |> validate_all_of(data, spec, path)
  end

  defp validate_any_of(errors, data, spec, path) do
    case spec[:anyOf] do
      nil ->
        errors

      schemas ->
        # At least one schema must validate
        valid? =
          Enum.any?(schemas, fn schema ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case validate_against_spec(data, schema, path) do
              {:ok, _} -> true
              {:error, _} -> false
            end
          end)

        if valid? do
          errors
        else
          [
            %{
              path: path,
              message: "must match at least one schema",
              constraint: :anyOf
            }
            | errors
          ]
        end
    end
  end

  defp validate_one_of(errors, data, spec, path) do
    case spec[:oneOf] do
      nil ->
        errors

      schemas ->
        # Exactly one schema must validate
        valid_count =
          Enum.count(schemas, fn schema ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case validate_against_spec(data, schema, path) do
              {:ok, _} -> true
              {:error, _} -> false
            end
          end)

        cond do
          valid_count == 1 ->
            errors

          valid_count == 0 ->
            [
              %{
                path: path,
                message: "must match exactly one schema (matched 0)",
                constraint: :oneOf
              }
              | errors
            ]

          true ->
            [
              %{
                path: path,
                message: "must match exactly one schema (matched #{valid_count})",
                constraint: :oneOf
              }
              | errors
            ]
        end
    end
  end

  defp validate_all_of(errors, data, spec, path) do
    case spec[:allOf] do
      nil ->
        errors

      schemas ->
        # All schemas must validate
        Enum.reduce(schemas, errors, fn schema, acc ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case validate_against_spec(data, schema, path) do
            {:ok, _} ->
              acc

            {:error, schema_errors} ->
              schema_errors ++ acc
          end
        end)
    end
  end

  # Conditional validation (if/then/else)
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_conditionals(errors, data, spec, path) do
    if_schema = spec[:if]
    then_schema = spec[:then]
    else_schema = spec[:else]

    if is_nil(if_schema) do
      errors
    else
      case validate_against_spec(data, if_schema, path) do
        {:ok, _} ->
          # If condition passed, validate against then schema
          if then_schema do
            case validate_against_spec(data, then_schema, path) do
              {:ok, _} -> errors
              {:error, then_errors} -> then_errors ++ errors
            end
          else
            errors
          end

        {:error, _} ->
          # If condition failed, validate against else schema
          if else_schema do
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case validate_against_spec(data, else_schema, path) do
              {:ok, _} -> errors
              {:error, else_errors} -> else_errors ++ errors
            end
          else
            errors
          end
      end
    end
  end

  # Format errors for display
  defp format_errors(errors) do
    errors
    |> Enum.map_join(", ", fn error ->
      path_str = format_path(error.path)
      "#{path_str}#{error.message}"
    end)
  end

  defp format_path([]), do: ""
  defp format_path(path), do: "#{Enum.join(path, ".")} "
end
