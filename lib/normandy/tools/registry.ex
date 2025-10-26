defmodule Normandy.Tools.Registry do
  @moduledoc """
  Manages a collection of tools available to an agent.

  The Registry provides a structured way to register, retrieve, and list
  tools that an agent can use during execution.
  """

  alias Normandy.Tools.BaseTool

  @type t :: %__MODULE__{
          tools: %{String.t() => struct()}
        }

  defstruct tools: %{}

  @doc """
  Creates a new empty tool registry.

  ## Examples

      iex> Normandy.Tools.Registry.new()
      %Normandy.Tools.Registry{tools: %{}}

  """
  @spec new() :: t()
  def new do
    %__MODULE__{tools: %{}}
  end

  @doc """
  Creates a new tool registry with the given tools.

  ## Examples

      iex> tools = [%MyTool{}, %OtherTool{}]
      iex> Normandy.Tools.Registry.new(tools)
      %Normandy.Tools.Registry{tools: %{"my_tool" => %MyTool{}, ...}}

  """
  @spec new([struct()]) :: t()
  def new(tools) when is_list(tools) do
    registry = new()
    Enum.reduce(tools, registry, fn tool, acc -> register(acc, tool) end)
  end

  @doc """
  Registers a tool in the registry.

  The tool is indexed by its `tool_name`.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new()
      iex> tool = %CalculatorTool{}
      iex> Normandy.Tools.Registry.register(registry, tool)
      %Normandy.Tools.Registry{tools: %{"calculator" => %CalculatorTool{}}}

  """
  @spec register(t(), struct()) :: t()
  def register(%__MODULE__{tools: tools} = registry, tool) do
    tool_name = BaseTool.tool_name(tool)
    %{registry | tools: Map.put(tools, tool_name, tool)}
  end

  @doc """
  Retrieves a tool by name from the registry.

  Returns `{:ok, tool}` if found, `:error` otherwise.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%CalculatorTool{}])
      iex> Normandy.Tools.Registry.get(registry, "calculator")
      {:ok, %CalculatorTool{}}

      iex> Normandy.Tools.Registry.get(registry, "nonexistent")
      :error

  """
  @spec get(t(), String.t()) :: {:ok, struct()} | :error
  def get(%__MODULE__{tools: tools}, tool_name) do
    Map.fetch(tools, tool_name)
  end

  @doc """
  Retrieves a tool by name, raising if not found.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%CalculatorTool{}])
      iex> Normandy.Tools.Registry.get!(registry, "calculator")
      %CalculatorTool{}

  """
  @spec get!(t(), String.t()) :: struct()
  def get!(%__MODULE__{} = registry, tool_name) do
    case get(registry, tool_name) do
      {:ok, tool} -> tool
      :error -> raise "Tool '#{tool_name}' not found in registry"
    end
  end

  @doc """
  Removes a tool from the registry by name.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%CalculatorTool{}])
      iex> Normandy.Tools.Registry.unregister(registry, "calculator")
      %Normandy.Tools.Registry{tools: %{}}

  """
  @spec unregister(t(), String.t()) :: t()
  def unregister(%__MODULE__{tools: tools} = registry, tool_name) do
    %{registry | tools: Map.delete(tools, tool_name)}
  end

  @doc """
  Returns a list of all registered tools.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%Tool1{}, %Tool2{}])
      iex> Normandy.Tools.Registry.list(registry)
      [%Tool1{}, %Tool2{}]

  """
  @spec list(t()) :: [struct()]
  def list(%__MODULE__{tools: tools}) do
    Map.values(tools)
  end

  @doc """
  Returns a list of all tool names in the registry.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%CalculatorTool{}])
      iex> Normandy.Tools.Registry.list_names(registry)
      ["calculator"]

  """
  @spec list_names(t()) :: [String.t()]
  def list_names(%__MODULE__{tools: tools}) do
    Map.keys(tools)
  end

  @doc """
  Returns the number of tools in the registry.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%Tool1{}, %Tool2{}])
      iex> Normandy.Tools.Registry.count(registry)
      2

  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{tools: tools}) do
    map_size(tools)
  end

  @doc """
  Checks if a tool with the given name exists in the registry.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%CalculatorTool{}])
      iex> Normandy.Tools.Registry.has_tool?(registry, "calculator")
      true

      iex> Normandy.Tools.Registry.has_tool?(registry, "nonexistent")
      false

  """
  @spec has_tool?(t(), String.t()) :: boolean()
  def has_tool?(%__MODULE__{tools: tools}, tool_name) do
    Map.has_key?(tools, tool_name)
  end

  @doc """
  Generates a list of tool schemas for LLM consumption.

  Returns a list of maps containing tool metadata (name, description, schema).

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%CalculatorTool{}])
      iex> Normandy.Tools.Registry.to_tool_schemas(registry)
      [
        %{
          name: "calculator",
          description: "Performs arithmetic operations",
          input_schema: %{type: "object", ...}
        }
      ]

  """
  @spec to_tool_schemas(t()) :: [map()]
  def to_tool_schemas(%__MODULE__{tools: tools}) do
    tools
    |> Map.values()
    |> Enum.map(fn tool ->
      %{
        name: BaseTool.tool_name(tool),
        description: BaseTool.tool_description(tool),
        input_schema: BaseTool.input_schema(tool)
      }
    end)
  end
end
