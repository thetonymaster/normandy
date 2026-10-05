defmodule Normandy.MCP.ToolWrapper do
  @moduledoc """
  Wraps an MCP tool as a `Normandy.Tool`.

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

  ## Trace context

  Unlike `Normandy.A2A.AgentTool`, an MCP call does not carry the W3C trace
  context to the server. `c:Claudio.MCP.Client.call_tool/4` takes the tool name,
  its arguments and transport options (a timeout), with no request metadata
  (MCP `_meta`) or header field, and the adapters build the request inside the
  MCP client library. Putting `traceparent` into the arguments would hand the
  tool an input it did not declare. The MCP server's spans therefore start a
  trace of their own.

  """

  use Normandy.Tool

  alias Normandy.Tools.Context

  @type t :: %__MODULE__{
          adapter: module(),
          client: term(),
          tool: Claudio.MCP.Client.Tool.t(),
          prefix: String.t() | nil
        }

  defstruct [:adapter, :client, :tool, :prefix]

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

  @impl Normandy.Tool
  def name(%__MODULE__{tool: tool, prefix: nil}), do: tool.name
  def name(%__MODULE__{tool: tool, prefix: prefix}), do: "#{prefix}__#{tool.name}"

  @impl Normandy.Tool
  def description(%__MODULE__{tool: %{description: nil} = tool}), do: "MCP tool: #{tool.name}"
  def description(%__MODULE__{tool: tool}), do: tool.description

  # The server's JSON Schema. Normandy.Tools.Input checks required keys, unknown keys and
  # basic types against it before run/2; a schema without `properties` accepts any keys
  # (decision 18), one with `properties` only those unless it sets `additionalProperties`.
  @impl Normandy.Tool
  def input_schema(%__MODULE__{tool: tool}), do: tool.input_schema

  @impl Normandy.Tool
  def run(%__MODULE__{adapter: adapter, client: client, tool: tool}, %Context{input: input}) do
    case adapter.call_tool(client, tool.name, input, []) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "MCP tool '#{tool.name}' failed: #{inspect(reason)}"}
    end
  end
end
