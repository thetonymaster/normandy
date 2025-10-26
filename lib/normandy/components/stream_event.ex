defmodule Normandy.Components.StreamEvent do
  @moduledoc """
  Represents a Server-Sent Event (SSE) from a streaming LLM response.

  Stream events are emitted incrementally as the LLM generates content,
  allowing for real-time display and processing.

  ## Event Types

  - `:message_start` - Stream begins, contains initial metadata
  - `:content_block_start` - New content block begins (text, tool_use, thinking)
  - `:content_block_delta` - Incremental content update
  - `:content_block_stop` - Content block complete
  - `:message_delta` - Message-level update (stop_reason, usage)
  - `:message_stop` - Stream complete
  - `:ping` - Keep-alive ping
  - `:error` - Error occurred

  ## Delta Types

  - `text_delta` - Incremental text content
  - `input_json_delta` - Incremental tool input JSON
  - `thinking_delta` - Extended thinking content

  ## Example

      # Text delta event
      %StreamEvent{
        type: :content_block_delta,
        index: 0,
        delta: %{type: "text_delta", text: "Hello"}
      }

      # Tool use delta
      %StreamEvent{
        type: :content_block_delta,
        index: 1,
        delta: %{type: "input_json_delta", partial_json: "{\\"location\\":"}
      }
  """

  use Normandy.Schema

  @type event_type ::
          :message_start
          | :content_block_start
          | :content_block_delta
          | :content_block_stop
          | :message_delta
          | :message_stop
          | :ping
          | :error

  @type delta_type :: :text_delta | :input_json_delta | :thinking_delta

  @type t :: %__MODULE__{
          type: event_type(),
          index: integer() | nil,
          delta: map() | nil,
          content_block: map() | nil,
          message: map() | nil,
          usage: map() | nil,
          error: String.t() | nil
        }

  schema do
    field(:type, :string)
    field(:index, :integer, default: nil)
    field(:delta, :map, default: nil)
    field(:content_block, :map, default: nil)
    field(:message, :map, default: nil)
    field(:usage, :map, default: nil)
    field(:error, :string, default: nil)
  end
end
