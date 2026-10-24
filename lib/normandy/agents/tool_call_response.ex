defmodule Normandy.Agents.ToolCallResponse do
  @moduledoc """
  Response schema for agent outputs that may include tool calls.

  This schema allows the LLM to either provide a final text response
  or request tool executions.

  `:thinking` holds the response's `thinking` and `redacted_thinking` blocks
  in their wire shape (string keys, with `signature` or `data`). They are sent
  back unchanged, first, when the turn is replayed: a thinking model needs
  them on the assistant message that carries the tool calls.

  `:prefix_key` (see `prefix_key/3`) records the system prompt, tools and model the
  response was produced under. The API accepts a thinking block only under that
  same prefix and model, so `Normandy.Components.AgentMemory.drop_stale_thinking/2` drops
  thinking whose key no longer matches. It is never sent to the API.

  `:content_blocks` holds the assistant turn as the API returned it: string-keyed,
  API-shaped blocks in their order (thinking, text with its citations, `tool_use`,
  `server_tool_use`, `mcp_tool_use` and their results), as
  `Claudio.Messages.Response.to_assistant_content/1` makes them. When it is not empty,
  the turn is replayed from it unchanged, so the next request carries exactly what the
  model produced; `:content`, `:tool_calls` and `:thinking` are what Normandy reads.
  A response built without it (by hand, or stored before it existed) is rebuilt from
  those three fields.

  `:stop_reason` is why the model stopped (`t:Normandy.LLM.Response.stop_reason/0`), or
  `nil` when the client did not say. The turn continues a `:pause_turn` response. It is
  never sent to the API.

  `:input_tokens` is the size of the request that produced the response as the provider
  counted it (input, cache reads and cache writes of the returned call), and
  `:estimated_input_tokens` Normandy's estimate of that request when it was sent; `nil`
  when unknown. `Normandy.Behaviours.Compactor.WindowManager` calibrates its estimate
  with their ratio (AX-12). Neither is sent to the API.
  """

  use Normandy.Schema

  alias Claudio.Messages.Response, as: ClaudioResponse
  alias Normandy.Components.ToolCall

  @type t :: %__MODULE__{
          content: String.t() | nil,
          tool_calls: [ToolCall.t()],
          thinking: [map()],
          prefix_key: integer() | nil,
          content_blocks: [map()],
          stop_reason: Normandy.LLM.Response.stop_reason() | nil,
          input_tokens: non_neg_integer() | nil,
          estimated_input_tokens: non_neg_integer() | nil
        }

  schema do
    field(:content, :string, default: nil)
    field(:tool_calls, {:array, :struct}, default: [])
    field(:thinking, {:array, :map}, default: [])
    field(:prefix_key, :integer, default: nil)
    field(:content_blocks, {:array, :map}, default: [])
    field(:stop_reason, :any, default: nil)
    field(:input_tokens, :integer, default: nil)
    field(:estimated_input_tokens, :integer, default: nil)
  end

  @doc """
  Whether `response` is a paused turn: its `stop_reason` is `pause_turn` (`:pause_turn`
  or `"pause_turn"`). Takes any map, since a streamed message reaches the turn as one
  and a struct stored before `:stop_reason` existed has no key; anything else is not paused.
  """
  @spec paused?(term()) :: boolean()
  def paused?(%{} = response), do: Map.get(response, :stop_reason) in [:pause_turn, "pause_turn"]
  def paused?(_response), do: false

  @doc """
  Whether `response` carries server-tool results: a content block with a `"tool_use_id"`
  (an MCP connector's `mcp_tool_result`, a `web_search_tool_result`). Reads
  `:content_blocks`, or `:content` when it is a list (a streamed message's blocks).
  """
  @spec server_results?(term()) :: boolean()
  def server_results?(response) do
    blocks =
      case response do
        %{content_blocks: [_ | _] = blocks} -> blocks
        %{content: [_ | _] = blocks} -> blocks
        _other -> []
      end

    Enum.any?(blocks, &match?(%{"tool_use_id" => _}, &1))
  end

  @doc """
  `:content_blocks` for a response's content blocks given as maps (a streamed message's
  string-keyed blocks): `Claudio.Messages.Response.to_assistant_content/1` of them, so a
  streamed turn is replayed in the same shape as a non-streamed one.
  """
  @spec api_blocks([map()]) :: [map()]
  def api_blocks(blocks) when is_list(blocks) do
    %{"content" => blocks}
    |> ClaudioResponse.from_map()
    |> ClaudioResponse.to_assistant_content()
  end

  @doc """
  A key for the part of a request a thinking block is bound to besides the
  messages: the system prompt, the tool set and the model. The API binds tools as
  a set sorted by name, so their order doesn't change the key.
  """
  @spec prefix_key(term(), [map()], String.t() | nil) :: non_neg_integer()
  def prefix_key(system_prompt, tools, model) do
    :erlang.phash2({system_prompt, Enum.sort_by(tools, &tool_name/1), model})
  end

  defp tool_name(tool), do: Map.get(tool, :name) || Map.get(tool, "name")

  @doc """
  The `thinking` and `redacted_thinking` blocks among response content blocks
  (atom or string keys), in order and in wire shape, for `:thinking`.
  """
  @spec thinking_blocks([map()]) :: [map()]
  def thinking_blocks(blocks) when is_list(blocks), do: Enum.flat_map(blocks, &thinking_block/1)

  defp thinking_block(block) do
    field = fn key -> Map.get(block, key) || Map.get(block, Atom.to_string(key)) end

    case field.(:type) do
      type when type in [:thinking, "thinking"] ->
        [
          %{
            "type" => "thinking",
            "thinking" => field.(:thinking),
            "signature" => field.(:signature)
          }
        ]

      type when type in [:redacted_thinking, "redacted_thinking"] ->
        [%{"type" => "redacted_thinking", "data" => field.(:data)}]

      _ ->
        []
    end
  end
end

defimpl Normandy.Components.BaseIOSchema, for: Normandy.Agents.ToolCallResponse do
  @moduledoc """
  BaseIOSchema protocol implementation for ToolCallResponse.

  Serializes ToolCallResponse to Claude API format with content blocks.
  """

  def to_json(%Normandy.Agents.ToolCallResponse{} = response) do
    # Map.get: a response stored before :content_blocks existed has no key.
    case Map.get(response, :content_blocks, []) do
      [] -> response.thinking ++ rebuilt_blocks(response)
      blocks -> replayed_blocks(blocks, response.thinking)
    end
  end

  # The turn as the API returned it. Thinking dropped from the response
  # (AgentMemory.drop_thinking/1 empties :thinking) is left out here too. A client
  # tool_use whose input is not an object goes back as {}: the API requires an
  # object, and Dispatch refused the call and told the model.
  defp replayed_blocks(blocks, thinking) do
    blocks
    |> Enum.reject(&(thinking == [] and thinking_block?(&1)))
    |> Enum.map(&object_input/1)
  end

  defp thinking_block?(%{"type" => type}), do: type in ["thinking", "redacted_thinking"]
  defp thinking_block?(_block), do: false

  defp object_input(%{"type" => "tool_use", "input" => input} = block) when not is_map(input),
    do: %{block | "input" => %{}}

  defp object_input(block), do: block

  # Thinking blocks first, as the API returned them, then the text and tool calls.
  defp rebuilt_blocks(%{content: content, tool_calls: tool_calls}) do
    # Build content blocks array for Claude API
    blocks = []

    # Add text content block if present
    blocks =
      if content && content != "" do
        [%{type: "text", text: content} | blocks]
      else
        blocks
      end

    # Add tool_use blocks
    blocks =
      Enum.reduce(tool_calls, blocks, fn tool_call, acc ->
        tool_block = %{
          type: "tool_use",
          id: tool_call.id,
          name: tool_call.name,
          # The API requires an object. Input that was not one was refused
          # (Dispatch.classify/3), and the model was told in the tool result.
          input: if(is_map(tool_call.input), do: tool_call.input, else: %{})
        }

        [tool_block | acc]
      end)

    # Reverse to maintain correct order (text first, then tool_uses)
    blocks = Enum.reverse(blocks)

    blocks
  end

  def get_schema(_), do: %{}
end
