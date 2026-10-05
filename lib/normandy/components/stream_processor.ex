defmodule Normandy.Components.StreamProcessor do
  @moduledoc """
  Utilities for processing streaming LLM responses.

  Provides functions to accumulate streaming events into complete messages,
  handle text deltas, and build final responses from event streams.
  """

  alias Normandy.LLMError

  @doc """
  Returns the failure a collected stream carries, or `nil` for a complete stream.

  A stream fails when it contains an `error` event (e.g. a mid-stream `overloaded_error`),
  an `{:error, reason}` item (a transport failure after the stream started), or ends
  without a `message_stop` event. The result is a `Normandy.LLMError` with `type: :stream`,
  `retryable?: false` (callbacks have already received partial output).
  """
  @spec stream_error([term()]) :: LLMError.t() | nil
  def stream_error(events) when is_list(events) do
    case Enum.find_value(events, &event_error/1) do
      %LLMError{} = error ->
        error

      nil ->
        if Enum.any?(events, &message_stop?/1),
          do: nil,
          else: stream_failure("stream ended before message_stop", nil)
    end
  end

  defp event_error(%{type: "error", error: error}),
    do: stream_failure(error_event_detail(error), error)

  defp event_error({:error, reason}), do: stream_failure("stream transport error", reason)
  defp event_error(_event), do: nil

  defp error_event_detail(%{"message" => message}) when is_binary(message), do: message
  defp error_event_detail(%{message: message}) when is_binary(message), do: message
  defp error_event_detail(_error), do: "error event in stream"

  defp message_stop?(%{type: "message_stop"}), do: true
  defp message_stop?(_event), do: false

  defp stream_failure(detail, reason),
    do: LLMError.new(type: :stream, retryable?: false, detail: detail, reason: reason)

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
    |> Stream.filter(&text_delta?/1)
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
  @spec build_final_message([map()]) :: map()
  def build_final_message(events) when is_list(events) do
    Enum.reduce(events, %{content: [], usage: %{}, stop_reason: nil}, fn event, acc ->
      process_event(event, acc)
    end)
  end

  # Private functions

  defp text_delta?(%{type: "content_block_delta", delta: %{"type" => "text_delta"}}), do: true
  defp text_delta?(_), do: false

  defp extract_text_delta(%{delta: %{"text" => text}}), do: text
  defp extract_text_delta(_), do: nil

  defp process_event(%{type: "message_start", message: message}, acc) do
    acc
    |> Map.merge(%{
      id: message["id"],
      model: message["model"],
      role: message["role"]
    })
    |> maybe_set_input_transformations(message["input_transformations"])
    |> maybe_update_usage(message["usage"])
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

        %{"type" => "thinking_delta", "thinking" => text} ->
          update_block(content, index, "thinking", &((&1 || "") <> text))

        %{"type" => "signature_delta", "signature" => signature} ->
          update_block(content, index, "signature", fn _ -> signature end)

        _ ->
          content
      end

    %{acc | content: updated_content}
  end

  # After a mid-stream fallback, message_delta repeats input_transformations with the
  # serving model's entries, replacing the message_start ones.
  defp process_event(%{type: "message_delta", delta: delta, usage: usage} = event, acc) do
    acc
    |> maybe_set_stop_reason(delta["stop_reason"])
    |> maybe_update_usage(usage)
    |> maybe_set_input_transformations(Map.get(event, :input_transformations))
  end

  # A finished tool_use block's accumulated JSON is decoded. Input that does not
  # decode to an object stays a string; Dispatch refuses it and tells the model.
  defp process_event(%{type: "content_block_stop", index: index}, acc) do
    content =
      List.update_at(acc.content || [], index, fn
        %{"type" => "tool_use", "input" => json} = block when is_binary(json) ->
          %{block | "input" => decode_tool_input(json)}

        block ->
          block
      end)

    %{acc | content: content}
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

  defp update_block(content, index, key, fun) do
    List.update_at(content, index, fn
      %{} = block -> Map.put(block, key, fun.(Map.get(block, key)))
      block -> block
    end)
  end

  defp decode_tool_input(""), do: %{}

  defp decode_tool_input(json) do
    case Application.get_env(:normandy, :adapter, Poison).decode(json) do
      {:ok, input} when is_map(input) -> input
      _ -> json
    end
  end

  defp maybe_set_stop_reason(acc, nil), do: acc
  defp maybe_set_stop_reason(acc, reason), do: Map.put(acc, :stop_reason, reason)

  defp maybe_set_input_transformations(acc, nil), do: acc

  defp maybe_set_input_transformations(acc, transformations),
    do: Map.put(acc, :input_transformations, transformations)

  defp maybe_update_usage(acc, nil), do: acc

  # message_start carries the input and cache counts, message_delta the running
  # output count (and possibly more); the later one wins, but a nil never
  # erases a count the earlier event reported.
  defp maybe_update_usage(acc, usage) when is_map(usage) do
    existing_usage = acc.usage || %{}
    updated_usage = Map.merge(existing_usage, Map.reject(usage, fn {_k, v} -> is_nil(v) end))
    Map.put(acc, :usage, updated_usage)
  end

  defp maybe_update_usage(acc, _usage), do: acc
end
