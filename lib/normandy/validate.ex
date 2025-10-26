defmodule Normandy.Validate do
  require Logger
  alias __MODULE__

  @empty_values [&Normandy.Type.empty_trimmed_string?/1]
  defstruct valid?: false,
            data: nil,
            params: nil,
            errors: [],
            validations: [],
            required: [],
            prepare: [],
            constraints: [],
            filters: %{},
            action: nil,
            types: %{},
            changes: []

  @type t(data_type) :: %Validate{
          valid?: boolean(),
          data: data_type,
          params: %{optional(String.t()) => term} | nil,
          required: [atom],
          prepare: [(t -> t)],
          errors: [{atom, error}],
          constraints: [constraint],
          validations: [validation],
          filters: %{optional(atom) => term},
          action: action,
          types: types
        }
  @type t :: t(Normandy.Schema.t() | map | nil)
  @type error :: {String.t(), Keyword.t()}
  @type action :: nil | :insert | :update | :delete | :replace | :ignore | atom
  @type constraint :: %{
          type: :check | :exclusion | :foreign_key | :unique,
          constraint: String.t() | Regex.t(),
          match: :exact | :suffix | :prefix,
          field: atom,
          error_message: String.t(),
          error_type: atom
        }
  @type data :: map()
  @type types :: %{atom => Normandy.Type.t() | {:assoc, term()} | {:embed, term()}}
  @type traverse_result :: %{atom => [term] | traverse_result}
  @type validation :: {atom, term}
  @type empty_value :: (term() -> boolean()) | binary() | list() | map() | tuple()

  @number_validators %{
    less_than: {&</2, "must be less than %{number}"},
    greater_than: {&>/2, "must be greater than %{number}"},
    less_than_or_equal_to: {&<=/2, "must be less than or equal to %{number}"},
    greater_than_or_equal_to: {&>=/2, "must be greater than or equal to %{number}"},
    equal_to: {&==/2, "must be equal to %{number}"},
    not_equal_to: {&!=/2, "must be not equal to %{number}"}
  }

  @spec empty_values() :: [empty_value()]
  def empty_values do
    @empty_values
  end

  @spec cast(
          Normandy.Schema.t() | t | {data, types},
          %{binary => term} | %{atom => term} | :invalid,
          [atom],
          Keyword.t()
        ) :: t
  def cast(data, params, permitted, opts \\ [])

  def cast(_data, %{__struct__: _} = params, _permitted, _opts) do
    raise Normandy.CastError,
      type: :map,
      value: params,
      message: "expected params to be a :map, got: `#{inspect(params)}`"
  end

  def cast(%{__struct__: module} = data, params, permitted, opts) do
    types = module.__specification__()
    cast(data, types, %{}, params, permitted, opts)
  end

  defp cast(%{} = data, %{} = types, %{} = changes, :invalid, permitted, _opts)
       when is_list(permitted) do
    _ = Enum.each(permitted, &cast_key/1)
    %Validate{params: nil, data: data, valid?: false, errors: [], changes: changes, types: types}
  end

  defp cast(%{} = data, %{} = types, %{} = changes, %{} = params, permitted, opts)
       when is_list(permitted) do
    empty_values = Keyword.get(opts, :empty_values, @empty_values)
    force? = Keyword.get(opts, :force_changes, false)
    params = convert_params(params)
    msg_func = Keyword.get(opts, :message, fn _, _ -> nil end)

    unless is_function(msg_func, 2) do
      raise ArgumentError,
            "expected `:message` to be a function of arity 2, received: #{inspect(msg_func)}"
    end

    defaults =
      case data do
        %{__struct__: struct} ->
          struct.__struct__()
          # %{} -> %{}
      end

    {changes, errors, valid?} =
      Enum.reduce(
        permitted,
        {changes, [], true},
        &process_param(&1, params, types, data, empty_values, defaults, force?, msg_func, &2)
      )

    %Validate{
      params: params,
      data: data,
      valid?: valid?,
      errors: Enum.reverse(errors),
      changes: changes,
      types: types
    }
  end

  defp cast(%{}, %{}, %{}, params, permitted, _opts) when is_list(permitted) do
    raise Normandy.CastError,
      type: :map,
      value: params,
      message: "expected params to be a :map, got: `#{inspect(params)}`"
  end

  defp process_param(
         key,
         params,
         types,
         data,
         empty_values,
         defaults,
         force?,
         msg_func,
         {changes, errors, valid?}
       ) do
    {key, param_key} = cast_key(key)
    type = cast_type!(types, key)

    current =
      case changes do
        %{^key => value} -> value
        _ -> Map.get(data, key)
      end

    case cast_field(key, param_key, type, params, current, empty_values, defaults, force?, valid?) do
      {:ok, value, valid?} ->
        {Map.put(changes, key, value), errors, valid?}

      :missing ->
        {changes, errors, valid?}

      {:invalid, custom_errors} ->
        {default_message, metadata} =
          custom_errors
          |> Keyword.put_new(:validation, :cast)
          |> Keyword.put(:type, type)
          |> Keyword.pop(:message, "is invalid")

        message =
          case msg_func.(key, metadata) do
            nil -> default_message
            user_message -> user_message
          end

        {changes, [{key, {message, metadata}} | errors], false}
    end
  end

  defp cast_type!(types, key) do
    case types do
      %{^key => type} ->
        type

      _ ->
        known_fields = types |> Map.keys() |> Enum.map_join(", ", &inspect/1)

        raise ArgumentError,
              "unknown field `#{inspect(key)}` given to cast. Either the field does not exist or it is a " <>
                ":through association (which are read-only). The known fields are: #{known_fields}"
    end
  end

  defp cast_key(key) when is_atom(key),
    do: {key, Atom.to_string(key)}

  defp cast_key(key) do
    raise ArgumentError, "cast/3 expects a list of atom keys, got key: `#{inspect(key)}`"
  end

  defp cast_field(key, param_key, type, params, current, empty_values, defaults, force?, valid?) do
    case params do
      %{^param_key => value} ->
        value = filter_empty_values(type, value, empty_values, defaults, key)

        case Normandy.Type.cast(type, value) do
          {:ok, value} ->
            if not force? and Normandy.Type.equal?(type, current, value) do
              :missing
            else
              {:ok, value, valid?}
            end

          :error ->
            {:invalid, []}

          {:error, custom_errors} when is_list(custom_errors) ->
            {:invalid, custom_errors}
        end

      _ ->
        :missing
    end
  end

  defp filter_empty_values(type, value, empty_values, defaults, key) do
    case filter_empty_values(type, value, empty_values) do
      :empty -> Map.get(defaults, key)
      {:ok, value} -> value
    end
  end

  defp filter_empty_values({:array, type}, value, empty_values) when is_list(value) do
    value =
      for elem <- value,
          {:ok, elem} <- [filter_empty_values(type, elem, empty_values)],
          do: elem

    if value in empty_values do
      :empty
    else
      {:ok, value}
    end
  end

  defp filter_empty_values(_type, value, empty_values) do
    filter_empty_value(empty_values, value)
  end

  defp filter_empty_value([head | tail], value) when is_function(head) do
    case head.(value) do
      true -> :empty
      false -> filter_empty_value(tail, value)
    end
  end

  defp filter_empty_value([value | _tail], value),
    do: :empty

  defp filter_empty_value([_head | tail], value),
    do: filter_empty_value(tail, value)

  defp filter_empty_value([], value),
    do: {:ok, value}

  defp convert_params(params) do
    case :maps.next(:maps.iterator(params)) do
      {key, _, _} when is_atom(key) ->
        for {key, value} <- params, into: %{} do
          if is_atom(key) do
            {Atom.to_string(key), value}
          else
            raise Normandy.CastError,
              type: :map,
              value: params,
              message:
                "expected params to be a map with atoms or string keys, " <>
                  "got a map with mixed keys: #{inspect(params)}"
          end
        end

      _ ->
        params
    end
  end

  @spec validations(t) :: [{atom, term}]
  def validations(%Validate{validations: validations}) do
    validations
  end

  @spec apply_changes(t) :: Normandy.Schema.t() | data
  def apply_changes(%Validate{changes: changes, data: data}) when changes == %{} do
    data
  end

  def apply_changes(%Validate{changes: changes, data: data, types: types}) do
    Enum.reduce(changes, data, fn {key, value}, acc ->
      case Map.fetch(types, key) do
        {:ok, _} ->
          Map.put(acc, key, value)

        :error ->
          acc
      end
    end)
  end

  @spec validate_required(t, list | atom, Keyword.t()) :: t
  def validate_required(%Validate{} = changeset, fields, opts \\ []) when not is_nil(fields) do
    %{required: required, errors: errors, changes: changes} = changeset
    fields = List.wrap(fields)

    fields_with_errors =
      for field <- fields,
          field_missing?(changeset, field),
          is_nil(errors[field]),
          do: field

    case fields_with_errors do
      [] ->
        %{changeset | required: fields ++ required}

      _ ->
        new_errors =
          Enum.map(
            fields_with_errors,
            &{&1, message(opts, "can't be blank", validation: :required)}
          )

        changes = Map.drop(changes, fields_with_errors)

        %{
          changeset
          | changes: changes,
            required: fields ++ required,
            errors: new_errors ++ errors,
            valid?: false
        }
    end
  end

  @spec field_missing?(t(), atom()) :: boolean()
  def field_missing?(%Validate{} = changeset, field) when not is_nil(field) do
    missing?(changeset, field) &&
      ensure_field_exists!(changeset, changeset.types, field)
  end

  defp missing?(changeset, field) when is_atom(field) do
    case get_field(changeset, field) do
      %{__struct__: Ecto.Association.NotLoaded} ->
        raise ArgumentError,
              "attempting to determine the presence of association `#{field}` " <>
                "that was not loaded. Please preload your associations " <>
                "before calling validate_required/3 or field_missing?/2. " <>
                "You may also consider passing the :required option to Ecto.Changeset.cast_assoc/3"

      value when is_binary(value) ->
        value == ""

      nil ->
        true

      _ ->
        false
    end
  end

  defp missing?(_changeset, field) do
    raise ArgumentError,
          "validate_required/3 and field_missing?/2 expect field names to be atoms, got: `#{inspect(field)}`"
  end

  @spec get_field(t, atom, term) :: term
  def get_field(%Validate{changes: changes, data: data, types: types}, key, default \\ nil) do
    case changes do
      %{^key => value} ->
        change_as_field(types, key, value)

      %{} ->
        case data do
          %{^key => value} -> data_as_field(data, types, key, value)
          %{} -> default
        end
    end
  end

  defp change_as_field(types, _key, value) do
    case types do
      %{} ->
        value
    end
  end

  defp data_as_field(_data, types, _key, value) do
    case types do
      %{} ->
        value
    end
  end

  defp ensure_field_exists!(changeset = %Validate{}, types, field) do
    unless Map.has_key?(types, field) do
      raise ArgumentError, "unknown field #{inspect(field)} in #{inspect(changeset.data)}"
    end

    true
  end

  defp message(opts, key \\ :message, default, message_opts) do
    case Keyword.get(opts, key, default) do
      {message, extra_opts} when is_binary(message) and is_list(extra_opts) ->
        {message, Keyword.merge(message_opts, extra_opts)}

      message when is_binary(message) ->
        {message, message_opts}
    end
  end

  def validate(data, params) do
    cast(data, params, data.__struct__.__schema__(:fields))
    |> validate_required(data.__struct__.__schema__(:fields))
  end

  @doc """
  Validates the given parameter is true.

  Note this validation only checks the parameter itself is true, never
  the field in the schema. That's because acceptance parameters do not need
  to be persisted, as by definition they would always be stored as `true`.

  ## Options

    * `:message` - the message on failure, defaults to "must be accepted".
      Can also be a `{msg, opts}` tuple, to provide additional options
      when using `traverse_errors/2`.

  ## Examples

      validate_acceptance(changeset, :terms_of_service)
      validate_acceptance(changeset, :rules, message: "please accept rules")

  """
  @spec validate_acceptance(t, atom, Keyword.t()) :: t
  def validate_acceptance(changeset, field, opts \\ [])

  def validate_acceptance(%{params: params} = changeset, field, opts) do
    errors = validate_acceptance_errors(params, field, opts)

    %{
      changeset
      | validations: [{field, {:acceptance, opts}} | changeset.validations],
        errors: errors ++ changeset.errors,
        valid?: changeset.valid? and errors == []
    }
  end

  defp validate_acceptance_errors(nil, _field, _opts), do: []

  defp validate_acceptance_errors(params, field, opts) do
    param = Atom.to_string(field)
    value = Map.get(params, param)

    case Normandy.Type.cast(:boolean, value) do
      {:ok, true} -> []
      _ -> [{field, message(opts, "must be accepted", validation: :acceptance)}]
    end
  end

  @spec validate_change(
          t,
          atom,
          (atom, term -> [{atom, String.t()} | {atom, error}])
        ) :: t
  def validate_change(%Validate{} = changeset, field, validator) when is_atom(field) do
    %{changes: changes, types: types, errors: errors} = changeset
    ensure_field_exists!(changeset, types, field)

    value = Map.get(changes, field)
    new = if is_nil(value), do: [], else: validator.(field, value)

    new =
      Enum.map(new, fn
        {key, val} when is_atom(key) and is_binary(val) ->
          {key, {val, []}}

        {key, {val, opts}} when is_atom(key) and is_binary(val) and is_list(opts) ->
          {key, {val, opts}}
      end)

    case new do
      [] -> changeset
      [_ | _] -> %{changeset | errors: new ++ errors, valid?: false}
    end
  end

  @spec validate_change(
          t,
          atom,
          term,
          (atom, term -> [{atom, String.t()} | {atom, error}])
        ) :: t
  def validate_change(
        %Validate{validations: validations} = changeset,
        field,
        metadata,
        validator
      ) do
    changeset = %{changeset | validations: [{field, metadata} | validations]}
    validate_change(changeset, field, validator)
  end

  @spec validate_format(t, atom, Regex.t(), Keyword.t()) :: t
  def validate_format(changeset, field, format, opts \\ []) do
    validate_change(changeset, field, {:format, format}, fn _, value ->
      unless is_binary(value) do
        raise ArgumentError,
              "validate_format/4 expects changes to be strings, received: #{inspect(value)} for field `#{field}`"
      end

      if value =~ format,
        do: [],
        else: [{field, message(opts, "has invalid format", validation: :format)}]
    end)
  end

  @spec validate_inclusion(t, atom, Enum.t(), Keyword.t()) :: t
  def validate_inclusion(changeset, field, data, opts \\ []) do
    validate_change(changeset, field, {:inclusion, data}, fn _, value ->
      type = Map.fetch!(changeset.types, field)

      if Normandy.Type.include?(type, value, data),
        do: [],
        else: [{field, message(opts, "is invalid", validation: :inclusion, enum: data)}]
    end)
  end

  @spec validate_subset(t, atom, Enum.t(), Keyword.t()) :: t
  def validate_subset(changeset, field, data, opts \\ []) do
    validate_change(changeset, field, {:subset, data}, fn _, value ->
      element_type =
        case Map.fetch!(changeset.types, field) do
          {:array, element_type} ->
            element_type

          type ->
            # backwards compatibility: custom types use underlying type
            {:array, element_type} = Normandy.Type.type(type)
            element_type
        end

      case Enum.any?(value, fn element ->
             not Normandy.Type.include?(element_type, element, data)
           end) do
        true ->
          [{field, message(opts, "has an invalid entry", validation: :subset, enum: data)}]

        false ->
          []
      end
    end)
  end

  @spec validate_exclusion(t, atom, Enum.t(), Keyword.t()) :: t
  def validate_exclusion(changeset, field, data, opts \\ []) do
    validate_change(changeset, field, {:exclusion, data}, fn _, value ->
      type = Map.fetch!(changeset.types, field)

      if Normandy.Type.include?(type, value, data),
        do: [{field, message(opts, "is reserved", validation: :exclusion, enum: data)}],
        else: []
    end)
  end

  @spec validate_length(t, atom, Keyword.t()) :: t
  def validate_length(changeset, field, opts) when is_list(opts) do
    validate_change(changeset, field, {:length, opts}, fn
      _, value ->
        count_type = opts[:count] || :graphemes

        {type, length} =
          case {value, count_type} do
            {value, :codepoints} when is_binary(value) ->
              {:string, codepoints_length(value, 0)}

            {value, :graphemes} when is_binary(value) ->
              {:string, String.length(value)}

            {value, :bytes} when is_binary(value) ->
              {:binary, byte_size(value)}

            {value, _} when is_list(value) ->
              {:list, length(value)}

            {value, _} when is_map(value) ->
              {:map, map_size(value)}
          end

        error =
          ((is = opts[:is]) && wrong_length(type, length, is, opts)) ||
            ((min = opts[:min]) && too_short(type, length, min, opts)) ||
            ((max = opts[:max]) && too_long(type, length, max, opts))

        if error, do: [{field, error}], else: []
    end)
  end

  defp codepoints_length(<<_::utf8, rest::binary>>, acc), do: codepoints_length(rest, acc + 1)
  defp codepoints_length(<<_, rest::binary>>, acc), do: codepoints_length(rest, acc + 1)
  defp codepoints_length(<<>>, acc), do: acc

  defp wrong_length(_type, value, value, _opts), do: nil

  defp wrong_length(:string, _length, value, opts),
    do:
      message(opts, "should be %{count} character(s)",
        count: value,
        validation: :length,
        kind: :is,
        type: :string
      )

  defp wrong_length(:binary, _length, value, opts),
    do:
      message(opts, "should be %{count} byte(s)",
        count: value,
        validation: :length,
        kind: :is,
        type: :binary
      )

  defp wrong_length(:list, _length, value, opts),
    do:
      message(opts, "should have %{count} item(s)",
        count: value,
        validation: :length,
        kind: :is,
        type: :list
      )

  defp wrong_length(:map, _length, value, opts),
    do:
      message(opts, "should have %{count} item(s)",
        count: value,
        validation: :length,
        kind: :is,
        type: :map
      )

  defp too_short(_type, length, value, _opts) when length >= value, do: nil

  defp too_short(:string, _length, value, opts) do
    message(opts, "should be at least %{count} character(s)",
      count: value,
      validation: :length,
      kind: :min,
      type: :string
    )
  end

  defp too_short(:binary, _length, value, opts) do
    message(opts, "should be at least %{count} byte(s)",
      count: value,
      validation: :length,
      kind: :min,
      type: :binary
    )
  end

  defp too_short(:list, _length, value, opts) do
    message(opts, "should have at least %{count} item(s)",
      count: value,
      validation: :length,
      kind: :min,
      type: :list
    )
  end

  defp too_short(:map, _length, value, opts) do
    message(opts, "should have at least %{count} item(s)",
      count: value,
      validation: :length,
      kind: :min,
      type: :map
    )
  end

  defp too_long(_type, length, value, _opts) when length <= value, do: nil

  defp too_long(:string, _length, value, opts) do
    message(opts, "should be at most %{count} character(s)",
      count: value,
      validation: :length,
      kind: :max,
      type: :string
    )
  end

  defp too_long(:binary, _length, value, opts) do
    message(opts, "should be at most %{count} byte(s)",
      count: value,
      validation: :length,
      kind: :max,
      type: :binary
    )
  end

  defp too_long(:list, _length, value, opts) do
    message(opts, "should have at most %{count} item(s)",
      count: value,
      validation: :length,
      kind: :max,
      type: :list
    )
  end

  defp too_long(:map, _length, value, opts) do
    message(opts, "should have at most %{count} item(s)",
      count: value,
      validation: :length,
      kind: :max,
      type: :map
    )
  end

  @spec validate_number(t, atom, Keyword.t()) :: t
  def validate_number(changeset, field, opts) do
    validate_change(changeset, field, {:number, opts}, fn
      field, value ->
        unless is_number(value) do
          raise ArgumentError,
                "expected field `#{field}` to be a decimal, integer, or float, got: #{inspect(value)}"
        end

        opts
        |> Keyword.drop([:message])
        |> Enum.find_value([], fn {spec_key, target_value} ->
          case Map.fetch(@number_validators, spec_key) do
            {:ok, {spec_function, default_message}} ->
              unless is_atom(target_value) do
                raise ArgumentError,
                      "expected option `#{spec_key}` to be a decimal, integer, or float, got: #{inspect(target_value)}"
              end

              compare_numbers(
                field,
                value,
                default_message,
                spec_key,
                spec_function,
                target_value,
                opts
              )

            :error ->
              supported_options =
                @number_validators |> Map.keys() |> Enum.map_join("\n", &"  * #{inspect(&1)}")

              raise ArgumentError, """
              unknown option #{inspect(spec_key)} given to validate_number/3

              The supported options are:

              #{supported_options}
              """
          end
        end)
    end)
  end

  defp compare_numbers(field, value, default_message, spec_key, spec_function, target_value, opts) do
    case apply(spec_function, [value, target_value]) do
      true ->
        nil

      false ->
        [
          {field,
           message(opts, default_message,
             validation: :number,
             kind: spec_key,
             number: target_value
           )}
        ]
    end
  end

  @spec validate_confirmation(t, atom, Keyword.t()) :: t
  def validate_confirmation(changeset, field, opts \\ [])

  def validate_confirmation(%{params: params} = changeset, field, opts) when is_map(params) do
    param = Atom.to_string(field)
    error_param = "#{param}_confirmation"
    error_field = String.to_atom(error_param)
    value = Map.get(params, param)

    errors =
      case params do
        %{^error_param => ^value} ->
          []

        %{^error_param => _} ->
          [
            {error_field, message(opts, "does not match confirmation", validation: :confirmation)}
          ]

        %{} ->
          confirmation_missing(opts, error_field)
      end

    %{
      changeset
      | validations: [{field, {:confirmation, opts}} | changeset.validations],
        errors: errors ++ changeset.errors,
        valid?: changeset.valid? and errors == []
    }
  end

  def validate_confirmation(%{params: nil} = changeset, _, _) do
    changeset
  end

  defp confirmation_missing(opts, error_field) do
    required = Keyword.get(opts, :required, false)

    if required,
      do: [{error_field, message(opts, "can't be blank", validation: :required)}],
      else: []
  end

  @spec apply_action(t, action) :: {:ok, Normandy.Schema.t() | data} | {:error, t}
  def apply_action(%Validate{} = changeset, action) when is_atom(action) do
    if changeset.valid? do
      {:ok, apply_changes(changeset)}
    else
      {:error, %Validate{changeset | action: action}}
    end
  end

  def apply_action(%Validate{}, action) do
    raise ArgumentError, "expected action to be an atom, got: #{inspect(action)}"
  end

  @spec apply_action!(t, action) :: Normandy.Schema.t() | data
  def apply_action!(%Validate{} = changeset, action) do
    case apply_action(changeset, action) do
      {:ok, data} ->
        data

      {:error, changeset} ->
        raise Normandy.InvalidChangesetError, action: action, changeset: changeset
    end
  end
  @spec traverse_errors(t, (error -> String.t()) | (Validate.t(), atom, error -> String.t())) ::
          traverse_result
  def traverse_errors(
        %Validate{errors: errors} = changeset,
        msg_func
      )
      when is_function(msg_func, 1) or is_function(msg_func, 3) do
    errors
    |> Enum.reverse()
    |> merge_keyword_keys(msg_func, changeset)
  end
  defp merge_keyword_keys(keyword_list, msg_func, _) when is_function(msg_func, 1) do
    Enum.reduce(keyword_list, %{}, fn {key, val}, acc ->
      val = msg_func.(val)
      Map.update(acc, key, [val], &[val | &1])
    end)
  end

  defp merge_keyword_keys(keyword_list, msg_func, changeset) when is_function(msg_func, 3) do
    Enum.reduce(keyword_list, %{}, fn {key, val}, acc ->
      val = msg_func.(changeset, key, val)
      Map.update(acc, key, [val], &[val | &1])
    end)
  end
end
