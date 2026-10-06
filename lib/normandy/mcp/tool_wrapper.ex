defmodule Normandy.MCP.ToolWrapper do
  @moduledoc """
  Wraps an MCP tool as a `Normandy.Tool`.

  This allows MCP tools discovered via any `Claudio.MCP.Client` adapter
  to be registered in a `Normandy.Tools.Toolset` and used in the agent's
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

  ## Results

  The server's `CallToolResult` reaches the model as text: its text blocks joined by
  newlines, and a one-line `[<type> content omitted]` note for each image, audio or
  resource block. A result with `isError: true` is an error result (`is_error` on the
  `tool_result`). A result in no known shape (no `content` list) is passed on as it is.

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

  alias Normandy.Options
  alias Normandy.Tools.Context

  @type t :: %__MODULE__{
          adapter: module(),
          client: term(),
          tool: Claudio.MCP.Client.Tool.t(),
          prefix: String.t() | nil
        }

  defstruct [:adapter, :client, :tool, :prefix]

  @new_opts_schema NimbleOptions.new!(
                     prefix: [
                       type: :string,
                       doc: "Namespaces the tool's name as `prefix__name`."
                     ]
                   )

  @doc false
  # Normandy.MCP.Registry takes its options from here (one source).
  def __opts_schema__(:new), do: @new_opts_schema

  @doc """
  Creates a new ToolWrapper for an MCP tool.

  ## Parameters

    - `adapter` - The MCP adapter module (e.g., `Claudio.MCP.Adapters.ExMCP`)
    - `client` - The MCP client connection
    - `tool` - A `Claudio.MCP.Client.Tool` struct
    - `opts` - see Options

  ## Options

  #{Options.docs(@new_opts_schema)}
  """
  @spec new(module(), term(), Claudio.MCP.Client.Tool.t(), keyword()) :: t()
  def new(adapter, client, tool, opts \\ []) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 4})

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
      {:ok, result} -> normalize_result(result)
      {:error, reason} -> {:error, "MCP tool '#{tool.name}' failed: #{inspect(reason)}"}
    end
  end

  # An MCP CallToolResult as the tool's return: its text blocks joined by newlines, a
  # one-line note for each block of another type, and `isError: true` as {:error, text}
  # (so the model gets is_error). Adapters hand it over as the JSON-RPC result map
  # (string keys), an atom-keyed map or struct (ExMCP.Response: :content, :is_error), or
  # a struct wrapping it under :result (Hermes). A binary, or any other term, is
  # returned as it is.
  defp normalize_result(result) when is_binary(result), do: {:ok, result}

  defp normalize_result(%{} = result) do
    inner = Map.get(result, :result)

    cond do
      is_list(content(result)) ->
        content_result(content(result), error_flag?(result))

      is_map(inner) and is_list(content(inner)) ->
        content_result(content(inner), error_flag?(result) or error_flag?(inner))

      true ->
        {:ok, result}
    end
  end

  defp normalize_result(result), do: {:ok, result}

  defp content(map), do: Map.get(map, "content", Map.get(map, :content))

  defp error_flag?(map),
    do: Enum.any?(["isError", :isError, "is_error", :is_error], &(Map.get(map, &1) == true))

  defp content_result(blocks, true) do
    case blocks_text(blocks) do
      "" -> {:error, "The MCP tool reported an error and sent no text."}
      text -> {:error, text}
    end
  end

  defp content_result(blocks, false), do: {:ok, blocks_text(blocks)}

  defp blocks_text(blocks), do: Enum.map_join(blocks, "\n", &block_text/1)

  defp block_text(%{} = block) do
    case Map.get(block, "type", Map.get(block, :type)) do
      type when type in ["text", :text] ->
        Map.get(block, "text", Map.get(block, :text)) || ""

      type when is_binary(type) or (is_atom(type) and not is_nil(type)) ->
        "[#{type} content omitted]"

      _other ->
        "[content omitted]"
    end
  end

  defp block_text(_block), do: "[content omitted]"
end
