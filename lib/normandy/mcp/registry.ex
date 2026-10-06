defmodule Normandy.MCP.Registry do
  @moduledoc """
  Helpers for discovering and registering MCP tools in a Normandy tool registry.

  ## Example

      alias Normandy.MCP.Registry, as: MCPRegistry
      alias Normandy.Tools.Toolset

      registry = Toolset.new()

      {:ok, registry} = MCPRegistry.discover_and_register(
        registry,
        Claudio.MCP.Adapters.ExMCP,
        mcp_client,
        prefix: "my_server"
      )

  """

  alias Normandy.MCP.ToolWrapper
  alias Normandy.Options
  alias Normandy.Tool
  alias Normandy.Tools.Toolset

  # The same options as ToolWrapper.new/4, which receives them (one source).
  @opts_schema ToolWrapper.__opts_schema__(:new)

  @doc false
  # BaseAgent.register_mcp_tools/4 takes its options from here.
  def __opts_schema__(:discover_and_register), do: @opts_schema

  @doc """
  Discovers tools from an MCP server and registers them in a tool registry.

  ## Options

  #{Options.docs(@opts_schema)}
  """
  @spec discover_and_register(Toolset.t(), module(), term(), keyword()) ::
          {:ok, Toolset.t()} | {:error, term()}
  def discover_and_register(%Toolset{} = registry, adapter, client, opts \\ []) do
    opts = Options.validate!(opts, @opts_schema, {__MODULE__, :discover_and_register, 4})

    case adapter.list_tools(client, []) do
      {:ok, tools} ->
        wrappers = wrap_tools(adapter, client, tools, opts)

        register_all(wrappers, registry)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Wraps a list of MCP tools as `ToolWrapper` structs.

  ## Options

  #{Options.docs(@opts_schema)}
  """
  @spec wrap_tools(module(), term(), [Claudio.MCP.Client.Tool.t()], keyword()) ::
          [ToolWrapper.t()]
  def wrap_tools(adapter, client, tools, opts \\ []) when is_list(tools) do
    opts = Options.validate!(opts, @opts_schema, {__MODULE__, :wrap_tools, 4})

    Enum.map(tools, fn tool ->
      ToolWrapper.new(adapter, client, tool, opts)
    end)
  end

  # A discovered name that is taken, or that the API would refuse, would otherwise
  # raise in Toolset.register/3; report it as this function's error instead.
  defp register_all(tools, registry) do
    Enum.reduce_while(tools, {:ok, registry}, fn tool, {:ok, reg} ->
      name = Tool.name(tool)

      cond do
        not Toolset.valid_name?(name) -> {:halt, {:error, {:invalid_tool_name, name}}}
        Toolset.has_tool?(reg, name) -> {:halt, {:error, {:tool_name_taken, name}}}
        true -> {:cont, {:ok, Toolset.register(reg, tool)}}
      end
    end)
  end
end
