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

  @doc """
  Gets metadata for a specific tool by name.

  Returns detailed metadata including schema introspection if available.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%CalculatorTool{}])
      iex> Normandy.Tools.Registry.get_metadata(registry, "calculator")
      {:ok, %{
        name: "calculator",
        description: "Performs arithmetic operations",
        input_schema: %{...},
        fields: [...]
      }}

  """
  @spec get_metadata(t(), String.t()) :: {:ok, map()} | :error
  def get_metadata(%__MODULE__{} = registry, tool_name) do
    case get(registry, tool_name) do
      {:ok, tool} ->
        metadata = build_tool_metadata(tool)
        {:ok, metadata}

      :error ->
        :error
    end
  end

  @doc """
  Gets metadata for all tools in the registry.

  Returns a list of metadata maps for each registered tool.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%Tool1{}, %Tool2{}])
      iex> Normandy.Tools.Registry.list_metadata(registry)
      [%{name: "tool1", ...}, %{name: "tool2", ...}]

  """
  @spec list_metadata(t()) :: [map()]
  def list_metadata(%__MODULE__{tools: tools}) do
    tools
    |> Map.values()
    |> Enum.map(&build_tool_metadata/1)
  end

  @doc """
  Filters tools by whether they have required parameters.

  Returns a new registry containing only tools that match the criteria.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%Tool1{}, %Tool2{}])
      iex> Normandy.Tools.Registry.filter_by_required_params(registry, true)
      %Normandy.Tools.Registry{tools: %{"tool1" => %Tool1{}}}

  """
  @spec filter_by_required_params(t(), boolean()) :: t()
  def filter_by_required_params(%__MODULE__{tools: tools} = registry, has_required?) do
    filtered_tools =
      tools
      |> Enum.filter(fn {_name, tool} ->
        has_required_params?(tool) == has_required?
      end)
      |> Map.new()

    %{registry | tools: filtered_tools}
  end

  @doc """
  Filters tools by parameter type.

  Returns a new registry containing only tools that have a parameter of the given type.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%Calculator{}, %StringTool{}])
      iex> Normandy.Tools.Registry.filter_by_param_type(registry, "number")
      %Normandy.Tools.Registry{tools: %{"calculator" => %Calculator{}}}

  """
  @spec filter_by_param_type(t(), String.t()) :: t()
  def filter_by_param_type(%__MODULE__{tools: tools} = registry, param_type) do
    filtered_tools =
      tools
      |> Enum.filter(fn {_name, tool} ->
        has_param_type?(tool, param_type)
      end)
      |> Map.new()

    %{registry | tools: filtered_tools}
  end

  @doc """
  Gets tools that support a specific constraint type.

  Returns a list of tool names that have parameters with the given constraint.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%Calculator{}, %StringTool{}])
      iex> Normandy.Tools.Registry.tools_with_constraint(registry, :enum)
      ["calculator", "string_tool"]

  """
  @spec tools_with_constraint(t(), atom()) :: [String.t()]
  def tools_with_constraint(%__MODULE__{tools: tools}, constraint_type) do
    tools
    |> Enum.filter(fn {_name, tool} ->
      has_constraint?(tool, constraint_type)
    end)
    |> Enum.map(fn {name, _tool} -> name end)
  end

  @doc """
  Gets schema introspection data for a tool if available.

  Returns schema field information for schema-based tools, or nil for legacy tools.

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%EnhancedCalculator{}])
      iex> Normandy.Tools.Registry.introspect_schema(registry, "enhanced_calculator")
      {:ok, [
        %{name: :operation, type: :string, required: true, ...},
        ...
      ]}

  """
  @spec introspect_schema(t(), String.t()) :: {:ok, [map()]} | {:ok, nil} | :error
  def introspect_schema(%__MODULE__{} = registry, tool_name) do
    case get(registry, tool_name) do
      {:ok, tool} ->
        schema_info = get_schema_introspection(tool)
        {:ok, schema_info}

      :error ->
        :error
    end
  end

  # Private helper functions

  defp build_tool_metadata(tool) do
    base_metadata = %{
      name: BaseTool.tool_name(tool),
      description: BaseTool.tool_description(tool),
      input_schema: BaseTool.input_schema(tool)
    }

    # Add schema introspection if available
    case get_schema_introspection(tool) do
      nil ->
        base_metadata

      fields ->
        Map.put(base_metadata, :fields, fields)
    end
  end

  defp get_schema_introspection(tool) do
    tool_module = tool.__struct__

    # Check if this is a schema-based tool with introspection support
    if function_exported?(tool_module, :__schema__, 1) do
      alias Normandy.Schema.Introspection

      fields = Introspection.list_fields(tool_module)
      required_fields = Introspection.get_required_fields(tool_module)

      Enum.map(fields, fn field_name ->
        field_type = Introspection.get_field_type(tool_module, field_name)
        field_meta = Introspection.get_field_metadata(tool_module, field_name)

        %{
          name: field_name,
          type: field_type,
          required: field_name in required_fields,
          metadata: field_meta
        }
      end)
    else
      nil
    end
  end

  defp has_required_params?(tool) do
    schema = BaseTool.input_schema(tool)

    case schema do
      %{required: required} when is_list(required) ->
        length(required) > 0

      _ ->
        false
    end
  end

  defp has_param_type?(tool, param_type) do
    schema = BaseTool.input_schema(tool)

    case schema do
      %{properties: properties} when is_map(properties) ->
        properties
        |> Map.values()
        |> Enum.any?(fn prop -> prop[:type] == param_type end)

      _ ->
        false
    end
  end

  defp has_constraint?(tool, constraint_type) do
    schema = BaseTool.input_schema(tool)

    case schema do
      %{properties: properties} when is_map(properties) ->
        properties
        |> Map.values()
        |> Enum.any?(fn prop -> Map.has_key?(prop, constraint_type) end)

      _ ->
        false
    end
  end
end
