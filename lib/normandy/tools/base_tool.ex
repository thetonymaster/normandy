defprotocol Normandy.Tools.BaseTool do
  @moduledoc """
  Protocol for implementing executable tools that agents can use.

  Tools represent external functions or capabilities that agents can invoke
  during their execution. Each tool must provide metadata (name, description,
  schema) and an execution implementation.
  """

  @doc """
  Returns the unique name identifier for this tool.

  ## Examples

      iex> tool = %MyTool{}
      iex> Normandy.Tools.BaseTool.tool_name(tool)
      "my_tool"

  """
  @spec tool_name(struct()) :: String.t()
  def tool_name(config)

  @doc """
  Returns a human-readable description of what this tool does.

  This description is used to help the LLM understand when and how to use
  the tool.

  ## Examples

      iex> tool = %CalculatorTool{}
      iex> Normandy.Tools.BaseTool.tool_description(tool)
      "Performs basic arithmetic operations on numbers"

  """
  @spec tool_description(struct()) :: String.t()
  def tool_description(config)

  @doc """
  Returns the JSON schema describing the tool's input parameters.

  The schema should follow the JSON Schema specification and describe
  all required and optional parameters for the tool.

  ## Examples

      iex> tool = %CalculatorTool{}
      iex> Normandy.Tools.BaseTool.input_schema(tool)
      %{
        type: "object",
        properties: %{
          operation: %{type: "string", enum: ["add", "subtract", "multiply", "divide"]},
          a: %{type: "number", description: "First operand"},
          b: %{type: "number", description: "Second operand"}
        },
        required: ["operation", "a", "b"]
      }

  """
  @spec input_schema(struct()) :: map()
  def input_schema(config)

  @doc """
  Executes the tool with the given configuration/parameters.

  Returns either `{:ok, result}` on success or `{:error, reason}` on failure.
  The result should be serializable to JSON.

  ## Examples

      iex> tool = %CalculatorTool{operation: :add, a: 5, b: 3}
      iex> Normandy.Tools.BaseTool.run(tool)
      {:ok, 8}

      iex> tool = %CalculatorTool{operation: :divide, a: 10, b: 0}
      iex> Normandy.Tools.BaseTool.run(tool)
      {:error, "Division by zero"}

  """
  @spec run(struct()) :: {:ok, term()} | {:error, String.t()}
  def run(config)
end
