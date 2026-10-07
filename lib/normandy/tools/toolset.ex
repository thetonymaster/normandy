defmodule Normandy.Tools.Toolset do
  @moduledoc """
  The tools an agent can call, by name.

  Each tool is a struct holding the tool's own configuration. `register/3` indexes it by its
  name and takes options that belong to the registration (see `register/3`).
  `to_tool_schemas/1` produces the tool definitions sent to the model.

  In the examples, `calculator`, `string_tool`, `tool1` and `tool2` stand for structs of
  modules that `use Normandy.Tool`, each named after its variable.
  """

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Schema.Introspection
  alias Normandy.Schema.Wire
  alias Normandy.Tool

  @type t :: %__MODULE__{
          tools: %{String.t() => struct()},
          timeouts: %{String.t() => pos_integer()},
          max_result_chars: %{String.t() => pos_integer() | nil}
        }

  defstruct tools: %{}, timeouts: %{}, max_result_chars: %{}

  @register_schema NimbleOptions.new!(
                     timeout: [
                       type: :pos_integer,
                       doc:
                         "Milliseconds a call to this tool may run before it fails with a timeout. " <>
                           "Without it, `Normandy.Tools.Executor.default_timeout/0` (30_000)."
                     ],
                     max_result_chars: [
                       type: {:or, [:pos_integer, nil]},
                       type_doc: "`t:pos_integer/0` or `nil`",
                       doc:
                         "The longest result of this tool, in characters (graphemes), the model " <>
                           "sees; `nil` = no cap. Without it, the agent's `:max_tool_result_chars`."
                     ],
                     replace: [
                       type: :boolean,
                       default: false,
                       doc:
                         "Replace a tool already registered under the same name instead of raising."
                     ]
                   )

  @doc "An empty toolset."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  A toolset holding `tools`, registered in order. An entry is a tool, or `{tool, opts}` to
  pass `opts` to `register/3`.

      Normandy.Tools.Toolset.new([%Search{}, {%Search{index: "b"}, replace: true}])
  """
  @spec new([struct() | {struct(), keyword()}]) :: t()
  def new(tools) when is_list(tools) do
    Enum.reduce(tools, new(), fn
      {tool, opts}, acc when is_list(opts) -> register(acc, tool, opts)
      tool, acc -> register(acc, tool, [])
    end)
  end

  @doc """
  Registers `tool` under its name.

  The name must be 1 to 64 letters, digits, underscores or dashes (what the API accepts);
  anything else raises `ArgumentError` here rather than as a 400 on the first request.
  Registering a second tool with the same name raises `ArgumentError` unless `replace: true`.
  A struct whose module does not implement `Normandy.Tool` (a 1.x tool) raises
  `ArgumentError` naming the module.
  An unknown or mistyped option raises `ArgumentError` naming it.

  ## Options

  #{Normandy.Options.docs(@register_schema)}
  """
  @spec register(t(), struct(), keyword()) :: t()
  def register(%__MODULE__{tools: tools} = toolset, tool, opts \\ []) do
    opts = Normandy.Options.validate!(opts, @register_schema, {__MODULE__, :register, 3})
    :ok = check_tool!(tool, "Normandy.Tools.Toolset.register/3")
    tool_name = Tool.name(tool)

    unless valid_name?(tool_name) do
      raise ArgumentError,
            "Normandy.Tools.Toolset.register/3: #{inspect(tool_name)} is not a valid tool name; " <>
              "the API accepts 1 to 64 letters, digits, underscores and dashes"
    end

    if Map.has_key?(tools, tool_name) and not Keyword.fetch!(opts, :replace) do
      raise ArgumentError,
            "Normandy.Tools.Toolset.register/3: a tool named #{inspect(tool_name)} is already " <>
              "registered; pass replace: true to replace it"
    end

    # An option left out drops what an earlier registration under the name set.
    %{
      toolset
      | tools: Map.put(tools, tool_name, tool),
        timeouts: put_or_delete(toolset.timeouts, tool_name, Keyword.fetch(opts, :timeout)),
        max_result_chars:
          put_or_delete(
            toolset.max_result_chars,
            tool_name,
            Keyword.fetch(opts, :max_result_chars)
          )
    }
  end

  defp put_or_delete(map, key, {:ok, value}), do: Map.put(map, key, value)
  defp put_or_delete(map, key, :error), do: Map.delete(map, key)

  @migration "see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour)"

  @doc false
  # Ruling 5: a 1.x tool reaches a 2.0 node only through registration or a template
  # supplement's toolset (ConfigTemplate.rebuild/3), so both check here. Names the module,
  # never the struct's values (they can be credentials).
  @spec check_tool!(term(), String.t()) :: :ok
  def check_tool!(%module{}, caller) do
    if Tool.implemented_by?(module) do
      :ok
    else
      raise ArgumentError,
            "#{caller}: #{inspect(module)} does not implement the Normandy.Tool behaviour. " <>
              "1.x tools (Normandy.Tools.BaseTool, SchemaBaseTool, ContextualTool) are " <>
              "replaced by it in 2.0; #{@migration}"
    end
  end

  def check_tool!(other, caller) do
    raise ArgumentError,
          "#{caller}: expected a tool struct whose module implements Normandy.Tool, got: " <>
            "#{Describe.type_of(other)}; #{@migration}"
  end

  @doc """
  The `:timeout` `tool_name` was registered with, or `nil` when it was registered without
  one (or is not registered).
  """
  @spec timeout(t(), String.t()) :: pos_integer() | nil
  def timeout(%__MODULE__{timeouts: timeouts}, tool_name), do: Map.get(timeouts, tool_name)

  @doc """
  The `:max_result_chars` `tool_name` was registered with: `{:ok, chars}`, `{:ok, nil}` (no
  cap), or `:error` when it was registered without one (the agent's
  `:max_tool_result_chars` applies) or is not registered.
  """
  @spec max_result_chars(t(), String.t()) :: {:ok, pos_integer() | nil} | :error
  def max_result_chars(%__MODULE__{max_result_chars: caps}, tool_name),
    do: Map.fetch(caps, tool_name)

  @doc "The tool registered as `tool_name`: `{:ok, tool}`, or `:error`."
  @spec fetch(t(), String.t()) :: {:ok, struct()} | :error
  def fetch(%__MODULE__{tools: tools}, tool_name), do: Map.fetch(tools, tool_name)

  @doc """
  The tool registered as `tool_name`. Raises `Normandy.ToolNotFoundError` (naming the
  registered tools) when there is none.
  """
  @spec fetch!(t(), String.t()) :: struct()
  def fetch!(%__MODULE__{tools: tools} = toolset, tool_name) do
    case fetch(toolset, tool_name) do
      {:ok, tool} ->
        tool

      :error ->
        raise Normandy.ToolNotFoundError,
          name: tool_name,
          registered: tools |> Map.keys() |> Enum.sort()
    end
  end

  @doc """
  Removes a tool from the toolset by name.

  ## Examples

      toolset = Normandy.Tools.Toolset.new([calculator])
      Normandy.Tools.Toolset.unregister(toolset, "calculator")
      #=> %Normandy.Tools.Toolset{tools: %{}, timeouts: %{}, max_result_chars: %{}}

  """
  @spec unregister(t(), String.t()) :: t()
  def unregister(%__MODULE__{} = toolset, tool_name) do
    %{
      toolset
      | tools: Map.delete(toolset.tools, tool_name),
        timeouts: Map.delete(toolset.timeouts, tool_name),
        max_result_chars: Map.delete(toolset.max_result_chars, tool_name)
    }
  end

  @doc """
  Returns a list of all registered tools.

  ## Examples

      toolset = Normandy.Tools.Toolset.new([tool1, tool2])
      Normandy.Tools.Toolset.list(toolset)
      #=> [tool1, tool2]

  """
  @spec list(t()) :: [struct()]
  def list(%__MODULE__{tools: tools}) do
    Map.values(tools)
  end

  @doc """
  Returns a list of all tool names in the toolset.

  ## Examples

      toolset = Normandy.Tools.Toolset.new([calculator])
      Normandy.Tools.Toolset.list_names(toolset)
      #=> ["calculator"]

  """
  @spec list_names(t()) :: [String.t()]
  def list_names(%__MODULE__{tools: tools}) do
    Map.keys(tools)
  end

  @doc """
  Returns the number of tools in the toolset.

  ## Examples

      toolset = Normandy.Tools.Toolset.new([tool1, tool2])
      Normandy.Tools.Toolset.count(toolset)
      #=> 2

  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{tools: tools}) do
    map_size(tools)
  end

  @doc """
  Checks if a tool with the given name exists in the toolset.

  ## Examples

      toolset = Normandy.Tools.Toolset.new([calculator])
      Normandy.Tools.Toolset.has_tool?(toolset, "calculator")
      #=> true

      Normandy.Tools.Toolset.has_tool?(toolset, "nonexistent")
      #=> false

  """
  @spec has_tool?(t(), String.t()) :: boolean()
  def has_tool?(%__MODULE__{tools: tools}, tool_name) do
    Map.has_key?(tools, tool_name)
  end

  @doc """
  Generates a list of tool schemas for LLM consumption.

  Returns a list of maps containing tool metadata (name, description, schema).

  ## Examples

      toolset = Normandy.Tools.Toolset.new([calculator])
      Normandy.Tools.Toolset.to_tool_schemas(toolset)
      #=> [
      #     %{
      #       name: "calculator",
      #       description: "Performs arithmetic operations",
      #       input_schema: %{type: "object", ...}
      #     }
      #   ]

  """
  @spec to_tool_schemas(t()) :: [map()]
  def to_tool_schemas(%__MODULE__{tools: tools}) do
    tools
    |> Map.values()
    |> Enum.map(fn tool ->
      %{
        name: Tool.name(tool),
        description: Tool.description(tool),
        input_schema: Wire.encodable(Tool.input_schema(tool))
      }
    end)
  end

  @doc """
  Gets metadata for a specific tool by name.

  Returns detailed metadata including schema introspection if available.

  ## Examples

      toolset = Normandy.Tools.Toolset.new([calculator])
      Normandy.Tools.Toolset.fetch_metadata(toolset, "calculator")
      #=> {:ok, %{
      #     name: "calculator",
      #     description: "Performs arithmetic operations",
      #     input_schema: %{...},
      #     fields: [...]
      #   }}

  """
  @spec fetch_metadata(t(), String.t()) :: {:ok, map()} | :error
  def fetch_metadata(%__MODULE__{} = toolset, tool_name) do
    case fetch(toolset, tool_name) do
      {:ok, tool} ->
        metadata = build_tool_metadata(tool)
        {:ok, metadata}

      :error ->
        :error
    end
  end

  @doc """
  Gets metadata for all tools in the toolset.

  Returns a list of metadata maps for each registered tool.

  ## Examples

      toolset = Normandy.Tools.Toolset.new([tool1, tool2])
      Normandy.Tools.Toolset.list_metadata(toolset)
      #=> [%{name: "tool1", ...}, %{name: "tool2", ...}]

  """
  @spec list_metadata(t()) :: [map()]
  def list_metadata(%__MODULE__{tools: tools}) do
    tools
    |> Map.values()
    |> Enum.map(&build_tool_metadata/1)
  end

  @doc """
  Gets schema introspection data for a tool if available.

  Returns schema field information for schema-based tools, or nil for legacy tools.

  ## Examples

      toolset = Normandy.Tools.Toolset.new([calculator])
      Normandy.Tools.Toolset.introspect_schema(toolset, "calculator")
      #=> {:ok, [
      #     %{name: :operation, type: :string, required: true, ...},
      #     ...
      #   ]}

  """
  @spec introspect_schema(t(), String.t()) :: {:ok, [map()]} | {:ok, nil} | :error
  def introspect_schema(%__MODULE__{} = toolset, tool_name) do
    case fetch(toolset, tool_name) do
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
      name: Tool.name(tool),
      description: Tool.description(tool),
      input_schema: Tool.input_schema(tool)
    }

    # Add schema introspection if available
    case get_schema_introspection(tool) do
      nil ->
        base_metadata

      fields ->
        Map.put(base_metadata, :fields, fields)
    end
  end

  # Field introspection for a tool that declared `input: Schema`; nil for a tool with a
  # hand-written input_schema/1 map.
  defp get_schema_introspection(%module{}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__tool_input__, 0) do
      input = module.__tool_input__()
      required_fields = Introspection.get_required_fields(input)

      Enum.map(Introspection.list_fields(input), fn field_name ->
        %{
          name: field_name,
          type: Introspection.get_field_type(input, field_name),
          required: field_name in required_fields,
          metadata: Introspection.get_field_metadata(input, field_name)
        }
      end)
    end
  end

  @doc """
  Whether `name` is a tool name the API accepts: 1 to 64 letters, digits,
  underscores and dashes. `register/3` raises on any other name.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: name =~ ~r/\A[a-zA-Z0-9_-]{1,64}\z/
  def valid_name?(_name), do: false
end
