defmodule Normandy.Agents.ValidationMiddleware do
  @moduledoc """
  Validation middleware for BaseAgent input/output schemas.

  Provides automatic validation of agent inputs and outputs using Normandy schemas,
  ensuring type safety and constraint enforcement throughout the agent lifecycle.

  ## Features

  - **Input Validation**: Validates user inputs before processing
  - **Output Validation**: Validates LLM responses before returning
  - **Clear Error Messages**: Path-based validation errors
  - **Optional Enforcement**: Can be disabled for backward compatibility

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

  alias Normandy.Schema.Validator
  alias Normandy.Agents.BaseAgentConfig

  @doc """
  Validates user input against the agent's input schema.

  Returns `{:ok, validated_struct}` on success or `{:error, errors}` on failure.
  If no input schema is defined or validation is disabled, returns the input unchanged.

  ## Examples

      iex> config = %BaseAgentConfig{input_schema: %MyInputSchema{}}
      iex> ValidationMiddleware.validate_input(config, %{query: "test"})
      {:ok, %MyInputSchema{query: "test"}}

      iex> ValidationMiddleware.validate_input(config, %{invalid: "data"})
      {:error, [%{path: [:query], message: "is required", constraint: :required}]}
  """
  @spec validate_input(BaseAgentConfig.t(), map() | struct() | nil) ::
          {:ok, struct()} | {:error, list()} | {:ok, nil}
  def validate_input(%BaseAgentConfig{input_schema: nil}, _input), do: {:ok, nil}
  def validate_input(%BaseAgentConfig{}, nil), do: {:ok, nil}

  def validate_input(%BaseAgentConfig{input_schema: input_schema}, input)
      when is_struct(input) do
    # Input is already a struct, check if it matches the schema
    if input.__struct__ == input_schema.__struct__ do
      {:ok, input}
    else
      # Convert struct to map for validation
      input_map = Map.from_struct(input)
      validate_input_map(input_schema, input_map)
    end
  end

  def validate_input(%BaseAgentConfig{input_schema: input_schema}, input)
      when is_map(input) do
    validate_input_map(input_schema, input)
  end

  defp validate_input_map(input_schema, input_map) do
    schema_module = input_schema.__struct__

    # Check if schema module has validation support
    if function_exported?(schema_module, :__schema__, 1) do
      case Validator.validate(schema_module, input_map) do
        {:ok, validated_params} ->
          {:ok, struct(schema_module, validated_params)}

        {:error, errors} ->
          {:error, format_validation_errors("Input", errors)}
      end
    else
      # Schema doesn't support validation, return as-is
      {:ok, input_schema}
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
    # Output is already a struct, optionally validate its contents
    if output.__struct__ == output_schema.__struct__ do
      {:ok, output}
    else
      # Different struct type - try to validate as map
      output_map = Map.from_struct(output)
      validate_output_map(output_schema, output_map)
    end
  end

  def validate_output(%BaseAgentConfig{output_schema: output_schema}, output)
      when is_map(output) do
    validate_output_map(output_schema, output)
  end

  defp validate_output_map(output_schema, output_map) do
    schema_module = output_schema.__struct__

    # Check if schema module has validation support
    if function_exported?(schema_module, :__schema__, 1) do
      case Validator.validate(schema_module, output_map) do
        {:ok, validated_params} ->
          {:ok, struct(schema_module, validated_params)}

        {:error, errors} ->
          {:error, format_validation_errors("Output", errors)}
      end
    else
      # Schema doesn't support validation, return as-is
      {:ok, output_schema}
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
  def validation_enabled?(%BaseAgentConfig{input_schema: nil, output_schema: nil}), do: false

  def validation_enabled?(%BaseAgentConfig{input_schema: input_schema})
      when not is_nil(input_schema) do
    schema_module = input_schema.__struct__
    function_exported?(schema_module, :__schema__, 1)
  end

  def validation_enabled?(%BaseAgentConfig{output_schema: output_schema})
      when not is_nil(output_schema) do
    schema_module = output_schema.__struct__
    function_exported?(schema_module, :__schema__, 1)
  end

  def validation_enabled?(_config), do: false

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
