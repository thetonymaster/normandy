defmodule Normandy.Components.StreamProcessor do
  @moduledoc """
  Utilities for processing streaming LLM responses.

  Provides functions to accumulate streaming events into complete messages,
  handle text deltas, and build final responses from event streams.
  """

  alias Normandy.Components.StreamEvent

  @doc """
  Accumulates text deltas from a stream of events.

  Returns a stream that emits accumulated text chunks.

  ## Example

      stream
      |> parse_stream_events()
      |> accumulate_text()
      |> Enum.each(&IO.write/1)
  """
  @spec accumulate_text(Enumerable.t()) :: Enumerable.t()
  def accumulate_text(event_stream) do
    event_stream
    |> Stream.filter(&is_text_delta?/1)
    |> Stream.map(&extract_text_delta/1)
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  Builds a complete message from all stream events.

  Accumulates all events and constructs a final response structure
  similar to non-streaming responses.

  ## Example

      events = Enum.to_list(stream)
      final_message = StreamProcessor.build_final_message(events)
  """
  @spec build_final_message([StreamEvent.t() | map()]) :: map()
  def build_final_message(events) when is_list(events) do
    Enum.reduce(events, %{content: [], usage: %{}, stop_reason: nil}, fn event, acc ->
      process_event(event, acc)
    end)
  end

  @doc """
  Invokes a callback for each event type.

  Callbacks receive `(event_type, data)` and should return `:ok` or `{:error, reason}`.

  ## Example

      callback = fn
        :text_delta, text -> IO.write(text)
        :tool_use, tool -> IO.puts("Tool: \#{tool.name}")
        _, _ -> :ok
      end

      StreamProcessor.process_with_callback(stream, callback)
  """
  @spec process_with_callback(Enumerable.t(), function()) :: {:ok, map()} | {:error, term()}
  def process_with_callback(event_stream, callback) when is_function(callback, 2) do
    try do
      events =
        event_stream
        |> Enum.map(fn event ->
          invoke_callback(event, callback)
          event
        end)

      final_message = build_final_message(events)
      {:ok, final_message}
    rescue
      error -> {:error, error}
    end
  end

  # Private functions

  defp is_text_delta?(%StreamEvent{type: :content_block_delta, delta: %{"type" => "text_delta"}}),
    do: true

  defp is_text_delta?(%{type: "content_block_delta", delta: %{"type" => "text_delta"}}), do: true
  defp is_text_delta?(_), do: false

  defp extract_text_delta(%StreamEvent{delta: %{"text" => text}}), do: text
  defp extract_text_delta(%{delta: %{"text" => text}}), do: text
  defp extract_text_delta(_), do: nil

  defp process_event(%{type: "message_start", message: message}, acc) do
    Map.merge(acc, %{
      id: message["id"],
      model: message["model"],
      role: message["role"]
    })
  end

  defp process_event(%{type: "content_block_start", content_block: block, index: index}, acc) do
    content = acc.content || []
    # Initialize content block at index
    new_content = List.insert_at(content, index, block)
    %{acc | content: new_content}
  end

  defp process_event(%{type: "content_block_delta", delta: delta, index: index}, acc) do
    content = acc.content || []

    updated_content =
      case delta do
        %{"type" => "text_delta", "text" => text} ->
          append_text_delta(content, index, text)

        %{"type" => "input_json_delta", "partial_json" => json} ->
          append_json_delta(content, index, json)

        _ ->
          content
      end

    %{acc | content: updated_content}
  end

  defp process_event(%{type: "message_delta", delta: delta, usage: usage}, acc) do
    acc
    |> maybe_set_stop_reason(delta["stop_reason"])
    |> maybe_update_usage(usage)
  end

  defp process_event(%{type: "message_stop"}, acc), do: acc
  defp process_event(_, acc), do: acc

  defp append_text_delta(content, index, text) do
    List.update_at(content, index, fn
      %{"type" => "text", "text" => existing} = block ->
        %{block | "text" => existing <> text}

      block ->
        block
    end)
  end

  defp append_json_delta(content, index, partial_json) do
    List.update_at(content, index, fn
      %{"type" => "tool_use", "input" => existing} = block when is_binary(existing) ->
        %{block | "input" => existing <> partial_json}

      %{"type" => "tool_use"} = block ->
        Map.put(block, "input", partial_json)

      block ->
        block
    end)
  end

  defp maybe_set_stop_reason(acc, nil), do: acc
  defp maybe_set_stop_reason(acc, reason), do: Map.put(acc, :stop_reason, reason)

  defp maybe_update_usage(acc, nil), do: acc

  defp maybe_update_usage(acc, usage) do
    existing_usage = acc.usage || %{}
    updated_usage = Map.merge(existing_usage, usage)
    Map.put(acc, :usage, updated_usage)
  end

  defp invoke_callback(
         %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}},
         callback
       ) do
    callback.(:text_delta, text)
  end

  defp invoke_callback(
         %{type: "content_block_start", content_block: %{"type" => "tool_use"} = tool},
         callback
       ) do
    callback.(:tool_use_start, tool)
  end

  defp invoke_callback(
         %{type: "content_block_delta", delta: %{"type" => "thinking_delta", "thinking" => text}},
         callback
       ) do
    callback.(:thinking_delta, text)
  end

  defp invoke_callback(%{type: "message_start", message: message}, callback) do
    callback.(:message_start, message)
  end

  defp invoke_callback(%{type: "message_stop"}, callback) do
    callback.(:message_stop, %{})
  end

  defp invoke_callback(_, _callback), do: :ok
end
