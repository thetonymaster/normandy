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
  alias Normandy.Tools.BaseTool
  alias Normandy.Tools.Toolset

  @doc """
  Discovers tools from an MCP server and registers them in a tool registry.

  ## Options

    - `:prefix` - Namespace prefix for tool names

  """
  @spec discover_and_register(Toolset.t(), module(), term(), keyword()) ::
          {:ok, Toolset.t()} | {:error, term()}
  def discover_and_register(%Toolset{} = registry, adapter, client, opts \\ []) do
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

    - `:prefix` - Namespace prefix for tool names

  """
  @spec wrap_tools(module(), term(), [Claudio.MCP.Client.Tool.t()], keyword()) ::
          [ToolWrapper.t()]
  def wrap_tools(adapter, client, tools, opts \\ []) when is_list(tools) do
    Enum.map(tools, fn tool ->
      ToolWrapper.new(adapter, client, tool, opts)
    end)
  end

  # A discovered name that is taken, or that the API would refuse, would otherwise
  # raise in Toolset.register/3; report it as this function's error instead.
  defp register_all(tools, registry) do
    Enum.reduce_while(tools, {:ok, registry}, fn tool, {:ok, reg} ->
      name = BaseTool.tool_name(tool)

      cond do
        not Toolset.valid_name?(name) -> {:halt, {:error, {:invalid_tool_name, name}}}
        Toolset.has_tool?(reg, name) -> {:halt, {:error, {:tool_name_taken, name}}}
        true -> {:cont, {:ok, Toolset.register(reg, tool)}}
      end
    end)
  end
end
