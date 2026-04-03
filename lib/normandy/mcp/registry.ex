defmodule Normandy.MCP.Registry do
  @moduledoc """
  Helpers for discovering and registering MCP tools in a Normandy tool registry.

  ## Example

      alias Normandy.MCP.Registry, as: MCPRegistry
      alias Normandy.Tools.Registry

      registry = Registry.new()

      {:ok, registry} = MCPRegistry.discover_and_register(
        registry,
        Claudio.MCP.Adapters.ExMCP,
        mcp_client,
        prefix: "my_server"
      )

  """

  alias Normandy.MCP.ToolWrapper
  alias Normandy.Tools.Registry

  @doc """
  Discovers tools from an MCP server and registers them in a tool registry.

  ## Options

    - `:prefix` - Namespace prefix for tool names

  """
  @spec discover_and_register(Registry.t(), module(), term(), keyword()) ::
          {:ok, Registry.t()} | {:error, term()}
  def discover_and_register(%Registry{} = registry, adapter, client, opts \\ []) do
    case adapter.list_tools(client, []) do
      {:ok, tools} ->
        wrappers = wrap_tools(adapter, client, tools, opts)

        updated_registry =
          Enum.reduce(wrappers, registry, fn wrapper, reg ->
            Registry.register(reg, wrapper)
          end)

        {:ok, updated_registry}

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
end
