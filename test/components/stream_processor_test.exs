defmodule Normandy.Components.StreamProcessorTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.StreamProcessor

  describe "accumulate_text/1" do
    test "extracts text deltas from stream events" do
      events = [
        %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => "Hello"}},
        %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => " world"}},
        %{type: "message_stop"}
      ]

      text_chunks = events |> StreamProcessor.accumulate_text() |> Enum.to_list()
      assert text_chunks == ["Hello", " world"]
    end

    test "filters out non-text events" do
      events = [
        %{type: "message_start", message: %{"id" => "msg_123"}},
        %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => "Hello"}},
        %{type: "content_block_start", content_block: %{"type" => "tool_use"}},
        %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => " world"}},
        %{type: "message_stop"}
      ]

      text_chunks = events |> StreamProcessor.accumulate_text() |> Enum.to_list()
      assert text_chunks == ["Hello", " world"]
    end

    test "handles empty stream" do
      events = []
      text_chunks = events |> StreamProcessor.accumulate_text() |> Enum.to_list()
      assert text_chunks == []
    end
  end

  describe "build_final_message/1" do
    test "builds complete message from text events" do
      events = [
        %{
          type: "message_start",
          message: %{"id" => "msg_123", "model" => "claude-3", "role" => "assistant"}
        },
        %{
          type: "content_block_start",
          content_block: %{"type" => "text", "text" => ""},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "text_delta", "text" => "Hello"},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "text_delta", "text" => " world"},
          index: 0
        },
        %{
          type: "message_delta",
          delta: %{"stop_reason" => "end_turn"},
          usage: %{"output_tokens" => 5}
        },
        %{type: "message_stop"}
      ]

      result = StreamProcessor.build_final_message(events)

      assert result.id == "msg_123"
      assert result.model == "claude-3"
      assert result.role == "assistant"
      assert result.stop_reason == "end_turn"
      assert result.usage == %{"output_tokens" => 5}
      assert length(result.content) == 1
      assert hd(result.content)["text"] == "Hello world"
    end

    test "builds message with tool use" do
      events = [
        %{
          type: "message_start",
          message: %{"id" => "msg_123", "model" => "claude-3", "role" => "assistant"}
        },
        %{
          type: "content_block_start",
          content_block: %{"type" => "tool_use", "id" => "tool_1", "name" => "calculator"},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "input_json_delta", "partial_json" => "{\"a\":"},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "input_json_delta", "partial_json" => "5}"},
          index: 0
        },
        %{type: "message_stop"}
      ]

      result = StreamProcessor.build_final_message(events)

      assert length(result.content) == 1
      tool_block = hd(result.content)
      assert tool_block["type"] == "tool_use"
      assert tool_block["id"] == "tool_1"
      assert tool_block["name"] == "calculator"
      assert tool_block["input"] == "{\"a\":5}"
    end

    test "builds message with mixed content" do
      events = [
        %{
          type: "message_start",
          message: %{"id" => "msg_123", "model" => "claude-3", "role" => "assistant"}
        },
        %{
          type: "content_block_start",
          content_block: %{"type" => "text", "text" => ""},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "text_delta", "text" => "Let me calculate"},
          index: 0
        },
        %{
          type: "content_block_start",
          content_block: %{"type" => "tool_use", "id" => "tool_1", "name" => "calculator"},
          index: 1
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "input_json_delta", "partial_json" => "{}"},
          index: 1
        },
        %{type: "message_stop"}
      ]

      result = StreamProcessor.build_final_message(events)

      assert length(result.content) == 2
      assert Enum.at(result.content, 0)["type"] == "text"
      assert Enum.at(result.content, 1)["type"] == "tool_use"
    end

    test "handles empty events list" do
      result = StreamProcessor.build_final_message([])

      assert result == %{content: [], usage: %{}, stop_reason: nil}
    end
  end

  describe "process_with_callback/2" do
    test "invokes callback for text deltas" do
      events = [
        %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => "Hello"}},
        %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => " world"}}
      ]

      callback = fn
        :text_delta, text -> send(self(), {:text, text})
        _, _ -> :ok
      end

      {:ok, _result} = StreamProcessor.process_with_callback(events, callback)

      assert_received {:text, "Hello"}
      assert_received {:text, " world"}
    end

    test "invokes callback for tool use start" do
      events = [
        %{
          type: "content_block_start",
          content_block: %{"type" => "tool_use", "name" => "calculator"}
        }
      ]

      callback = fn
        :tool_use_start, tool -> send(self(), {:tool, tool["name"]})
        _, _ -> :ok
      end

      {:ok, _result} = StreamProcessor.process_with_callback(events, callback)

      assert_received {:tool, "calculator"}
    end

    test "invokes callback for message lifecycle" do
      events = [
        %{type: "message_start", message: %{"id" => "msg_123"}},
        %{type: "message_stop"}
      ]

      callback = fn
        :message_start, msg -> send(self(), {:start, msg["id"]})
        :message_stop, _ -> send(self(), :stop)
        _, _ -> :ok
      end

      {:ok, _result} = StreamProcessor.process_with_callback(events, callback)

      assert_received {:start, "msg_123"}
      assert_received :stop
    end

    test "returns final accumulated message" do
      events = [
        %{
          type: "message_start",
          message: %{"id" => "msg_123", "model" => "claude-3", "role" => "assistant"}
        },
        %{
          type: "content_block_start",
          content_block: %{"type" => "text", "text" => ""},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "text_delta", "text" => "Hello"},
          index: 0
        }
      ]

      callback = fn _, _ -> :ok end

      {:ok, result} = StreamProcessor.process_with_callback(events, callback)

      assert result.id == "msg_123"
      assert length(result.content) == 1
    end
  end
end
