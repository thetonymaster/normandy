defmodule Normandy.Tools.SchemaBaseTool do
  @moduledoc """
  Mixin module for creating tools with Normandy schema-based input definitions.

  This module provides a convenient way to define tools using Normandy's schema system,
  automatically generating JSON schemas and providing runtime validation of tool inputs.

  ## Benefits

  - **DRY**: Single source of truth for tool input structure
  - **Validation**: Automatic runtime validation before tool execution
  - **Type Safety**: Leverage Normandy's type system with constraints
  - **Format Validation**: Built-in support for email, UUID, URI, etc.
  - **Better Errors**: Path-based error messages for invalid inputs

  ## Usage

      defmodule MyTool do
        use Normandy.Tools.SchemaBaseTool

        tool_schema "my_tool", "Does something useful" do
          field(:query, :string, required: true, description: "Search query", min_length: 1)
          field(:limit, :integer, description: "Max results", default: 10, minimum: 1, maximum: 100)
          field(:email, :string, description: "Contact email", format: "email")
        end

        @impl true
        def execute(%__MODULE__{query: query, limit: limit}) do
          # Your tool logic here
          {:ok, "Processed: \#{query} with limit \#{limit}"}
        end
      end

  ## Automatic Features

  The `tool_schema` macro automatically:
  - Defines a struct with the specified fields
  - Generates JSON Schema from field definitions
  - Implements `Normandy.Tools.BaseTool` protocol
  - Provides `validate/1` function for runtime validation
  - Handles default values and type coercion

  ## Validation

  Input validation happens automatically when tools are executed through
  `Normandy.Tools.Executor`. Invalid inputs return `{:error, validation_errors}`.

  You can also manually validate:

      tool_params = %{query: "test", limit: 5}
      case MyTool.validate(tool_params) do
        {:ok, validated} -> MyTool.execute(validated)
        {:error, errors} -> {:error, errors}
      end
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Normandy.Tools.SchemaBaseTool, only: [tool_schema: 3]
      use Normandy.Schema
    end
  end

  @doc """
  Defines a tool with a schema-based input specification.

  ## Parameters

  - `tool_name` - The unique identifier for this tool (string)
  - `description` - Human-readable description of what the tool does
  - `do` block - Schema field definitions using `field/3`

  ## Examples

      tool_schema "calculator", "Performs arithmetic operations" do
        field(:operation, :string, required: true, enum: ["add", "subtract", "multiply", "divide"])
        field(:a, :float, required: true, description: "First operand")
        field(:b, :float, required: true, description: "Second operand")
      end
  """
  defmacro tool_schema(tool_name, description, do: block) do
    quote do
      # Set module attributes first, before any code that uses them
      @tool_name unquote(tool_name)
      @tool_description unquote(description)

      # Define the schema
      io_schema unquote(description) do
        unquote(block)
      end

      @doc """
      Validates input parameters against the tool's schema.

      Returns `{:ok, struct}` on success or `{:error, errors}` on validation failure.

      ## Examples

          iex> #{__MODULE__}.validate(%{operation: "add", a: 5, b: 3})
          {:ok, %#{__MODULE__}{operation: "add", a: 5, b: 3}}

          iex> #{__MODULE__}.validate(%{operation: "invalid"})
          {:error, [%{path: [:a], message: "is required", constraint: :required}]}
      """
      @spec validate(map()) :: {:ok, struct()} | {:error, list()}
      def validate(params) when is_map(params) do
        case Normandy.Schema.Validator.validate(__MODULE__, params) do
          {:ok, validated_params} ->
            {:ok, struct(__MODULE__, validated_params)}

          {:error, errors} ->
            {:error, errors}
        end
      end

      @doc """
      Validates and raises on error.

      Returns the validated struct or raises `Normandy.Schema.ValidationError`.
      """
      @spec validate!(map()) :: struct()
      def validate!(params) when is_map(params) do
        case validate(params) do
          {:ok, tool_struct} ->
            tool_struct

          {:error, errors} ->
            raise Normandy.Schema.ValidationError,
              message: "Tool input validation failed",
              errors: errors
        end
      end

      @doc """
      Executes the tool with validated inputs.

      This function must be implemented by the tool. It receives a validated struct
      with all fields populated according to the schema.

      Returns `{:ok, result}` on success or `{:error, reason}` on failure.

      ## Examples

          @impl Normandy.Tools.SchemaBaseTool
          def execute(%__MODULE__{operation: "add", a: a, b: b}) do
            {:ok, a + b}
          end

          def execute(%__MODULE__{operation: "divide", a: _a, b: 0}) do
            {:error, "Division by zero"}
          end
      """
      @callback execute(struct()) :: {:ok, term()} | {:error, String.t()}

      # Implement BaseTool protocol
      defimpl Normandy.Tools.BaseTool do
        def tool_name(_), do: unquote(tool_name)

        def tool_description(_), do: unquote(description)

        def input_schema(_) do
          # Get the JSON Schema specification from the module
          @for.__schema__(:specification)
        end

        def run(tool_struct) do
          # Execute the tool implementation
          @for.execute(tool_struct)
        end
      end
    end
  end
end
