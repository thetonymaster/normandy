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

      wrapper = ToolWrapper.new(Claudio.MCP.Adapters.ExMCP, mcp_client_pid, mcp_tool, prefix: "web")

      # The model sees the tool as "web__search".
      agent = BaseAgent.register_tool(agent, wrapper)

  ## Results

  The server's `CallToolResult` reaches the model as text: its text blocks joined by
  newlines, and a one-line `[<type> content omitted]` note for each image, audio or
  resource block. A result with `isError: true` is an error result (`is_error` on the
  `tool_result`). A result in no known shape (no `content` list) is passed on as it is.

  ## Tool names and policy rules

  The server chooses its tools' names, so a name says nothing about what a tool does. A
  `Normandy.Behaviours.PolicyEngine.Ruleset` rule matches the name only: a server that
  names a destructive tool `read_and_purge` matches the rule `"read_*"`. That is why
  `:prefix` is required. The model sees `prefix <> "__" <> name`, so the rule `"web__*"`
  matches exactly the tools of the server you gave the prefix `"web"` (and any local tool
  you chose to name `web__...`).

  A prefix is letters, digits, `-` and single `_` (no `__`, no `_` at either end), at
  most 61 bytes, so the first `__` in a name always ends the prefix. The whole name must
  still be a valid tool name (`^[a-zA-Z0-9_-]{1,64}$`): with a prefix, a server's tool
  name can be at most `62 - byte_size(prefix)` bytes, and a server with a longer or
  dotted name fails registration (`{:error, {:invalid_tool_name, name}}`).

  `prefix: false` keeps the server's own names. Use it only for a server you control, and
  write no name-glob rule such a server could match.

  ## Trust

  An MCP server is outside your trust boundary. Its tool descriptions and input schemas
  are sent to the model on every request, and its results become the model's input: each
  is a prompt-injection channel that Normandy passes through unchanged. Connect servers
  you trust as much as your own tools' code, and gate tools that change state with a
  policy (`:require_approval`) rather than trusting a server's names or descriptions.

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

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Options
  alias Normandy.Tools.Context

  @type t :: %__MODULE__{
          adapter: module(),
          client: term(),
          tool: Claudio.MCP.Client.Tool.t(),
          prefix: String.t() | false
        }

  @enforce_keys [:adapter, :client, :tool, :prefix]
  defstruct [:adapter, :client, :tool, :prefix]

  @prefix_format ~r/\A[a-zA-Z0-9-]+(?:_[a-zA-Z0-9-]+)*\z/
  @max_prefix_bytes 61

  @new_opts_schema NimbleOptions.new!(
                     prefix: [
                       type: {:custom, __MODULE__, :validate_prefix, []},
                       type_doc: "`t:String.t/0` or `false`",
                       required: true,
                       doc:
                         "The server's namespace: the model sees each tool as `prefix__name`. " <>
                           "Letters, digits, `-` and single `_` (no `__`, no `_` at either " <>
                           "end), at most 61 bytes. `false` keeps the server's own names " <>
                           "(see \"Tool names and policy rules\")."
                     ]
                   )

  @doc false
  # Normandy.MCP.Registry takes its options from here (one source).
  def __opts_schema__(:new), do: @new_opts_schema

  @doc false
  # The NimbleOptions custom type of :prefix, here and on Normandy.A2A.AgentTool.
  @spec validate_prefix(term()) :: {:ok, String.t() | false} | {:error, String.t()}
  def validate_prefix(false), do: {:ok, false}

  def validate_prefix(prefix) when is_binary(prefix) do
    if byte_size(prefix) <= @max_prefix_bytes and Regex.match?(@prefix_format, prefix),
      do: {:ok, prefix},
      else: {:error, prefix_rule() <> ", got: #{inspect(prefix)}"}
  end

  def validate_prefix(other), do: {:error, prefix_rule() <> ", got: " <> Describe.type_of(other)}

  defp prefix_rule do
    "expected false or a prefix of letters, digits, - and single _ (no __, no _ at either " <>
      "end), at most #{@max_prefix_bytes} bytes"
  end

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
      prefix: Keyword.fetch!(opts, :prefix)
    }
  end

  @impl Normandy.Tool
  def name(%__MODULE__{tool: tool, prefix: false}), do: tool.name

  def name(%__MODULE__{tool: tool, prefix: prefix}) when is_binary(prefix),
    do: prefix <> "__" <> tool.name

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
      {:ok, result} ->
        normalize_result(result)

      # The reason's tag only: a transport error can carry the response body the server sent.
      {:error, reason} ->
        {:error, "MCP tool '#{tool.name}' failed: #{Describe.reason_tag(reason)}"}
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
