defmodule Normandy.MCP.ToolWrapper do
  @moduledoc """
  Wraps an MCP tool as a Normandy `BaseTool` implementation.

  This allows MCP tools discovered via any `Claudio.MCP.Client` adapter
  to be registered in a Normandy tool registry and used in the agent's
  tool execution loop.

  ## Example

      alias Claudio.MCP.Client.Tool
      alias Normandy.MCP.ToolWrapper

      mcp_tool = %Tool{
        name: "search",
        description: "Search the web",
        input_schema: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
      }

      wrapper = %ToolWrapper{
        adapter: Claudio.MCP.Adapters.ExMCP,
        client: mcp_client_pid,
        tool: mcp_tool,
        prefix: "my_server"
      }

      # Register in agent
      agent = BaseAgent.register_tool(agent, wrapper)

  """

  @type t :: %__MODULE__{
          adapter: module(),
          client: term(),
          tool: Claudio.MCP.Client.Tool.t(),
          prefix: String.t() | nil,
          input: map()
        }

  defstruct [:adapter, :client, :tool, :prefix, input: %{}]

  @doc """
  Creates a new ToolWrapper for an MCP tool.

  ## Parameters

    - `adapter` - The MCP adapter module (e.g., `Claudio.MCP.Adapters.ExMCP`)
    - `client` - The MCP client connection
    - `tool` - A `Claudio.MCP.Client.Tool` struct
    - `opts` - Options including `:prefix` for namespacing

  """
  @spec new(module(), term(), Claudio.MCP.Client.Tool.t(), keyword()) :: t()
  def new(adapter, client, tool, opts \\ []) do
    %__MODULE__{
      adapter: adapter,
      client: client,
      tool: tool,
      prefix: Keyword.get(opts, :prefix)
    }
  end

  @doc """
  Prepares the tool with LLM-provided input parameters.

  Called by the BaseAgent tool loop instead of `struct/2` for tools
  with dynamic input schemas.
  """
  @spec prepare_input(t(), map()) :: t()
  def prepare_input(%__MODULE__{} = wrapper, input) when is_map(input) do
    %{wrapper | input: input}
  end

  defimpl Normandy.Tools.BaseTool do
    def tool_name(%{tool: tool, prefix: nil}), do: tool.name

    def tool_name(%{tool: tool, prefix: prefix}) do
      "#{prefix}__#{tool.name}"
    end

    def tool_description(%{tool: tool}) do
      tool.description || "MCP tool: #{tool.name}"
    end

    def input_schema(%{tool: tool}) do
      tool.input_schema
    end

    def run(%{adapter: adapter, client: client, tool: tool, input: input}) do
      case adapter.call_tool(client, tool.name, input, []) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, "MCP tool '#{tool.name}' failed: #{inspect(reason)}"}
      end
    end
  end
end
