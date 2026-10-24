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
  alias Normandy.Schema.Wire
  alias Normandy.Tool

  defmodule Entry do
    @moduledoc false
    # One registration: the tool and the options it was registered with. A `nil` timeout is
    # "none given"; `max_result_chars` is `:unset` when none was given, since `nil` there means
    # "no cap".
    @enforce_keys [:tool]
    defstruct [:tool, :timeout, max_result_chars: :unset]

    @type t :: %__MODULE__{
            tool: struct(),
            timeout: pos_integer() | nil,
            max_result_chars: pos_integer() | nil | :unset
          }
  end

  @typedoc """
  A toolset. `tools` maps each tool's name to its registration: an internal struct holding
  the tool and the options `register/3` took, not the tool itself. Read the tools with
  `list/1` and `fetch/2`, not from the map.
  """
  @type t :: %__MODULE__{tools: %{String.t() => struct()}}

  defstruct tools: %{}

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
    entry = %Entry{
      tool: tool,
      timeout: Keyword.get(opts, :timeout),
      max_result_chars: Keyword.get(opts, :max_result_chars, :unset)
    }

    %{toolset | tools: Map.put(tools, tool_name, entry)}
  end

  @doc false
  # `register/3` for discovered tools: a name the API would refuse or one already taken is
  # an error tuple, where `register/3` raises.
  @spec register_new(t(), struct(), keyword()) ::
          {:ok, t()} | {:error, {:invalid_tool_name | :tool_name_taken, term()}}
  def register_new(%__MODULE__{} = toolset, tool, opts \\ []) do
    name = Tool.name(tool)

    cond do
      not valid_name?(name) -> {:error, {:invalid_tool_name, name}}
      has_tool?(toolset, name) -> {:error, {:tool_name_taken, name}}
      true -> {:ok, register(toolset, tool, opts)}
    end
  end

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
  def timeout(%__MODULE__{tools: tools}, tool_name) do
    case Map.fetch(tools, tool_name) do
      {:ok, %Entry{timeout: timeout}} -> timeout
      :error -> nil
    end
  end

  @doc """
  The `:max_result_chars` `tool_name` was registered with: `{:ok, chars}`, `{:ok, nil}` (no
  cap), or `:error` when it was registered without one (the agent's
  `:max_tool_result_chars` applies) or is not registered.
  """
  @spec max_result_chars(t(), String.t()) :: {:ok, pos_integer() | nil} | :error
  def max_result_chars(%__MODULE__{tools: tools}, tool_name) do
    case Map.fetch(tools, tool_name) do
      {:ok, %Entry{max_result_chars: chars}} when chars != :unset -> {:ok, chars}
      _ -> :error
    end
  end

  @doc "The tool registered as `tool_name`: `{:ok, tool}`, or `:error`."
  @spec fetch(t(), String.t()) :: {:ok, struct()} | :error
  def fetch(%__MODULE__{tools: tools}, tool_name) do
    with {:ok, %Entry{tool: tool}} <- Map.fetch(tools, tool_name), do: {:ok, tool}
  end

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
      #=> %Normandy.Tools.Toolset{tools: %{}}

  """
  @spec unregister(t(), String.t()) :: t()
  def unregister(%__MODULE__{tools: tools} = toolset, tool_name),
    do: %{toolset | tools: Map.delete(tools, tool_name)}

  @doc """
  Returns a list of all registered tools.

  ## Examples

      toolset = Normandy.Tools.Toolset.new([tool1, tool2])
      Normandy.Tools.Toolset.list(toolset)
      #=> [tool1, tool2]

  """
  @spec list(t()) :: [struct()]
  def list(%__MODULE__{tools: tools}) do
    Enum.map(tools, fn {_name, %Entry{tool: tool}} -> tool end)
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
    Enum.map(tools, fn {_name, %Entry{tool: tool}} ->
      %{
        name: Tool.name(tool),
        description: Tool.description(tool),
        input_schema: Wire.encodable(Tool.input_schema(tool))
      }
    end)
  end

  @doc """
  Whether `name` is a tool name the API accepts: 1 to 64 letters, digits,
  underscores and dashes. `register/3` raises on any other name.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: name =~ ~r/\A[a-zA-Z0-9_-]{1,64}\z/
  def valid_name?(_name), do: false
end
