defmodule Normandy.Agents.ValidationMiddleware do
  @moduledoc """
  Validation middleware for BaseAgent input/output schemas.

  Provides automatic validation of agent inputs and outputs using Normandy schemas,
  ensuring type safety and constraint enforcement throughout the agent lifecycle.

  ## Features

  - **Input Validation**: Validates user inputs before processing
  - **Output Validation**: Validates LLM responses before returning
  - **Clear Error Messages**: Path-based validation errors
  - **Opt-in**: Runs only for a schema that can validate (a Normandy schema);
    any other input or output passes through unchanged

  ## Usage

      # Validate input
      case ValidationMiddleware.validate_input(config, user_input) do
        {:ok, validated_input} -> # proceed
        {:error, errors} -> # handle validation failure
      end

      # Validate output
      case ValidationMiddleware.validate_output(config, response) do
        {:ok, validated_response} -> # proceed
        {:error, errors} -> # handle validation failure
      end
  """

  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Schema.Validator

  @doc """
  Validates user input against the agent's input schema.

  Returns `{:ok, validated_struct}` on success or `{:error, errors}` on failure.
  If no input schema is defined or validation is disabled, returns the input unchanged.

  ## Examples

      iex> config = %BaseAgentConfig{input_schema: %MyInputSchema{}}
      iex> ValidationMiddleware.validate_input(config, %{query: "test"})
      {:ok, %MyInputSchema{query: "test"}}

      iex> ValidationMiddleware.validate_input(
      ...>   %BaseAgentConfig{input_schema: %BaseAgentInputSchema{}},
      ...>   "hello"
      ...> )
      {:ok, %BaseAgentInputSchema{chat_message: "hello"}}

      iex> ValidationMiddleware.validate_input(config, %{invalid: "data"})
      {:error, [%{path: [:query], message: "is required", constraint: :required}]}
  """
  @spec validate_input(BaseAgentConfig.t(), term()) ::
          {:ok, term()} | {:error, list()}
  def validate_input(%BaseAgentConfig{input_schema: nil}, input), do: {:ok, input}
  def validate_input(%BaseAgentConfig{}, nil), do: {:ok, nil}

  def validate_input(%BaseAgentConfig{input_schema: %BaseAgentInputSchema{}}, text)
      when is_binary(text),
      do: {:ok, %BaseAgentInputSchema{chat_message: text}}

  # A default-schema struct is checked like a map: %BaseAgentInputSchema{chat_message: nil}
  # would otherwise send an empty user turn.
  def validate_input(
        %BaseAgentConfig{input_schema: %BaseAgentInputSchema{}},
        %BaseAgentInputSchema{} = input
      ),
      do: validate_base_input(Map.from_struct(input))

  def validate_input(%BaseAgentConfig{input_schema: input_schema}, input) when is_map(input) do
    # Check if input is a struct
    if is_map_key(input, :__struct__) do
      # Input is already a struct, check if it matches the schema
      if input.__struct__ == input_schema.__struct__ do
        {:ok, input}
      else
        # Convert struct to map for validation
        input_map = Map.from_struct(input)
        validate_input_map(input_schema, input_map)
      end
    else
      # Input is a plain map
      validate_input_map(input_schema, input)
    end
  end

  # Content blocks (multimodal input) pass through to the default schema's agent unvalidated.
  def validate_input(%BaseAgentConfig{input_schema: %BaseAgentInputSchema{}}, blocks)
      when is_list(blocks),
      do: {:ok, blocks}

  # Anything but a map or struct can't be cast into a schema.
  def validate_input(%BaseAgentConfig{input_schema: %schema{}}, input) do
    {:error,
     format_validation_errors("Input", [
       %{
         path: [],
         message: "expected a map or %#{inspect(schema)}{}, got: #{Describe.type_of(input)}",
         constraint: :type
       }
     ])}
  end

  defp validate_input_map(input_schema, input_map) do
    schema_module = input_schema.__struct__
    input_map = atomize_field_keys(input_schema, input_map)

    cond do
      schema_module == Normandy.Agents.BaseAgentInputSchema ->
        validate_base_input(input_map)

      # Check if schema module has validation support
      Code.ensure_loaded?(schema_module) and function_exported?(schema_module, :__schema__, 1) ->
        case Validator.validate(schema_module, input_map) do
          {:ok, validated_params} ->
            {:ok, struct(schema_module, validated_params)}

          {:error, errors} ->
            {:error, format_validation_errors("Input", errors)}
        end

      # Schema doesn't support validation: keep the caller's input as-is
      true ->
        {:ok, input_map}
    end
  end

  # The default schema has one field. struct/2 would drop a typo such as
  # :chat_mesage and send a nil user turn, so check the keys and the type here.
  defp validate_base_input(input_map) do
    case Map.keys(input_map) -- [:chat_message, :__meta__, "__meta__"] do
      [] ->
        case Map.get(input_map, :chat_message) do
          message when is_binary(message) ->
            {:ok, %Normandy.Agents.BaseAgentInputSchema{chat_message: message}}

          other ->
            {:error,
             format_validation_errors("Input", [
               %{
                 path: [:chat_message],
                 message: "must be a string, got: #{inspect(other)}",
                 constraint: :type
               }
             ])}
        end

      unknown ->
        {:error,
         format_validation_errors("Input", [
           %{
             path: unknown,
             message:
               "unknown keys #{inspect(unknown)} for the default input schema; " <>
                 "expected only :chat_message",
             constraint: :unknown_keys
           }
         ])}
    end
  end

  @doc """
  Validates LLM output against the agent's output schema.

  Returns `{:ok, validated_struct}` on success or `{:error, errors}` on failure.
  If no output schema is defined or validation is disabled, returns the output unchanged.

  ## Examples

      iex> config = %BaseAgentConfig{output_schema: %MyOutputSchema{}}
      iex> ValidationMiddleware.validate_output(config, %{result: "success"})
      {:ok, %MyOutputSchema{result: "success"}}

      iex> ValidationMiddleware.validate_output(config, %{invalid: "data"})
      {:error, [%{path: [:result], message: "is required", constraint: :required}]}
  """
  @spec validate_output(BaseAgentConfig.t(), struct() | map() | nil) ::
          {:ok, struct()} | {:error, list()} | {:ok, nil}
  def validate_output(%BaseAgentConfig{output_schema: nil}, _output), do: {:ok, nil}
  def validate_output(%BaseAgentConfig{}, nil), do: {:ok, nil}

  def validate_output(%BaseAgentConfig{output_schema: output_schema}, output)
      when is_struct(output) do
    cond do
      # An output already of the schema's struct is checked like any other: a client
      # that builds the struct itself must not bypass the schema's constraints.
      # The struct comes back as it is (the validator does not cast).
      output.__struct__ == output_schema.__struct__ and validating_schema?(output_schema) ->
        case validate_output_map(output_schema, present_fields(output)) do
          {:ok, _validated} -> {:ok, output}
          {:error, _errors} = error -> error
        end

      # A schema without validation support has nothing to check, and
      # validate_output_map/2 would turn the struct into a plain map.
      output.__struct__ == output_schema.__struct__ ->
        {:ok, output}

      # Different struct type - try to validate as map
      true ->
        validate_output_map(output_schema, Map.from_struct(output))
    end
  end

  def validate_output(%BaseAgentConfig{output_schema: output_schema}, output)
      when is_map(output) do
    validate_output_map(output_schema, output)
  end

  defp validate_output_map(output_schema, output_map) do
    schema_module = output_schema.__struct__
    output_map = atomize_field_keys(output_schema, output_map)

    # Skip validation for base schemas (backward compatibility)
    cond do
      schema_module == Normandy.Agents.BaseAgentOutputSchema ->
        {:ok, struct(schema_module, output_map)}

      # Check if schema module has validation support
      Code.ensure_loaded?(schema_module) and function_exported?(schema_module, :__schema__, 1) ->
        case Validator.validate(schema_module, output_map) do
          {:ok, validated_params} ->
            {:ok, struct(schema_module, validated_params)}

          {:error, errors} ->
            {:error, format_validation_errors("Output", errors)}
        end

      # Schema doesn't support validation: keep the output as-is
      true ->
        {:ok, output_map}
    end
  end

  @doc """
  Formats validation errors into user-friendly messages.

  ## Examples

      iex> errors = [%{path: [:name], message: "is required", constraint: :required}]
      iex> ValidationMiddleware.format_validation_errors("Input", errors)
      [%{
        type: "Input validation error",
        path: [:name],
        message: "is required",
        constraint: :required
      }]
  """
  @spec format_validation_errors(String.t(), list()) :: list()
  def format_validation_errors(context, errors) when is_list(errors) do
    Enum.map(errors, fn error ->
      Map.put(error, :type, "#{context} validation error")
    end)
  end

  @doc """
  Checks if validation is enabled for the agent configuration.

  Validation is considered enabled if the agent has schemas with validation support.

  ## Examples

      iex> config = %BaseAgentConfig{input_schema: %MySchema{}}
      iex> ValidationMiddleware.validation_enabled?(config)
      true
  """
  @spec validation_enabled?(BaseAgentConfig.t()) :: boolean()
  def validation_enabled?(%BaseAgentConfig{input_schema: input, output_schema: output}),
    do: validating_schema?(input) or validating_schema?(output)

  # JSON and form params arrive string-keyed, and struct/2 and the validator look
  # up atom fields. A string key that names a field becomes that field's atom;
  # other keys are left as they are (never String.to_atom/1 on caller input).
  defp atomize_field_keys(schema, map) do
    fields =
      schema
      |> Map.keys()
      |> Map.new(&{Atom.to_string(&1), &1})
      |> Map.drop(["__struct__", "__meta__"])

    Map.new(map, fn
      {key, value} when is_binary(key) -> {Map.get(fields, key, key), value}
      pair -> pair
    end)
  end

  # A schema struct as the validator reads decoded JSON: a struct has every key, so a
  # nil field is an absent one. It descends into fields that are schema structs or lists,
  # not into plain maps: a schema struct inside a plain map is left as it is, as are
  # other values (dates, other structs).
  defp present_fields(%_{} = struct) do
    if validating_schema?(struct) do
      struct
      |> Map.from_struct()
      |> Map.delete(:__meta__)
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Map.new(fn {field, value} -> {field, present_fields(value)} end)
    else
      struct
    end
  end

  defp present_fields(list) when is_list(list), do: Enum.map(list, &present_fields/1)
  defp present_fields(other), do: other

  defp validating_schema?(nil), do: false

  defp validating_schema?(%mod{}),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1)

  @doc """
  Validates and returns a sanitized error message for display.

  Converts validation error list into a human-readable string.

  ## Examples

      iex> errors = [
      ...>   %{path: [:name], message: "is required", constraint: :required},
      ...>   %{path: [:age], message: "must be at least 0", constraint: :minimum}
      ...> ]
      iex> ValidationMiddleware.error_message(errors)
      "Validation failed:\\n  - name: is required\\n  - age: must be at least 0"
  """
  @spec error_message(list()) :: String.t()
  def error_message(errors) when is_list(errors) do
    error_lines =
      Enum.map(errors, fn error ->
        path = Enum.join(error.path, ".")
        "  - #{path}: #{error.message}"
      end)

    "Validation failed:\n" <> Enum.join(error_lines, "\n")
  end
end
