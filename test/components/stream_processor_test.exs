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

  describe "build_final_message/1 input_transformations" do
    @dropped %{"type" => "thinking_dropped", "path" => "messages.1.content.0"}

    test "usage merges message_start's counts with message_delta's, a nil never erasing one" do
      events = [
        %{
          type: "message_start",
          message: %{
            "id" => "m",
            "usage" => %{
              "input_tokens" => 10,
              "output_tokens" => 1,
              "cache_read_input_tokens" => 100
            }
          }
        },
        %{
          type: "message_delta",
          delta: %{"stop_reason" => "end_turn"},
          usage: %{"output_tokens" => 7, "cache_read_input_tokens" => nil}
        }
      ]

      assert StreamProcessor.build_final_message(events).usage == %{
               "input_tokens" => 10,
               "output_tokens" => 7,
               "cache_read_input_tokens" => 100
             }
    end

    test "keeps the input_transformations reported in message_start" do
      events = [
        %{type: "message_start", message: %{"id" => "m", "input_transformations" => [@dropped]}},
        %{type: "message_stop"}
      ]

      assert StreamProcessor.build_final_message(events).input_transformations == [@dropped]
    end

    test "a message_delta's input_transformations replace the message_start ones" do
      later = %{@dropped | "path" => "messages.3.content.0"}

      events = [
        %{type: "message_start", message: %{"id" => "m", "input_transformations" => [@dropped]}},
        %{type: "message_delta", delta: %{}, usage: nil, input_transformations: [later]},
        %{type: "message_stop"}
      ]

      assert StreamProcessor.build_final_message(events).input_transformations == [later]
    end

    test "a message_delta without them keeps the message_start ones" do
      events = [
        %{type: "message_start", message: %{"id" => "m", "input_transformations" => [@dropped]}},
        %{type: "message_delta", delta: %{"stop_reason" => "end_turn"}, usage: nil},
        %{type: "message_stop"}
      ]

      assert StreamProcessor.build_final_message(events).input_transformations == [@dropped]
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

  describe "stream_error/1" do
    @complete [
      %{type: "message_start", message: %{"id" => "m"}},
      %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => "hi"}, index: 0},
      %{type: "message_stop"}
    ]

    test "nil for a complete stream" do
      assert StreamProcessor.stream_error(@complete) == nil
    end

    test "an error event becomes a :stream LLMError carrying the API message" do
      events = [
        %{type: "message_start", message: %{}},
        %{type: "error", error: %{"type" => "overloaded_error", "message" => "Overloaded"}}
      ]

      assert %Normandy.LLMError{
               type: :stream,
               retryable?: false,
               message: message,
               reason: reason
             } =
               StreamProcessor.stream_error(events)

      assert message == "LLM call failed: stream: Overloaded"
      assert reason == %{"type" => "overloaded_error", "message" => "Overloaded"}
    end

    test "an {:error, reason} item becomes a :stream LLMError" do
      assert %Normandy.LLMError{type: :stream, reason: :closed} =
               StreamProcessor.stream_error([
                 %{type: "message_start", message: %{}},
                 {:error, :closed}
               ])
    end

    test "a stream that ends without message_stop is an error" do
      assert %Normandy.LLMError{
               type: :stream,
               message: "LLM call failed: stream: stream ended before message_stop"
             } =
               StreamProcessor.stream_error(Enum.drop(@complete, -1))
    end
  end

  describe "content the final message keeps" do
    test "a tool_use input is decoded once its block stops" do
      events = [
        %{
          type: "content_block_start",
          content_block: %{"type" => "tool_use", "id" => "t", "input" => %{}},
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
        %{type: "content_block_stop", index: 0}
      ]

      assert %{content: [%{"input" => %{"a" => 5}}]} = StreamProcessor.build_final_message(events)
    end

    test "a tool_use with no input deltas has an empty object input" do
      events = [
        %{
          type: "content_block_start",
          content_block: %{"type" => "tool_use", "id" => "t", "input" => %{}},
          index: 0
        },
        %{type: "content_block_stop", index: 0}
      ]

      assert %{content: [%{"input" => %{}}]} = StreamProcessor.build_final_message(events)
    end

    test "thinking text and its signature are accumulated" do
      events = [
        %{
          type: "content_block_start",
          content_block: %{"type" => "thinking", "thinking" => ""},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "thinking_delta", "thinking" => "Let me "},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "thinking_delta", "thinking" => "think."},
          index: 0
        },
        %{
          type: "content_block_delta",
          delta: %{"type" => "signature_delta", "signature" => "sig"},
          index: 0
        },
        %{type: "content_block_stop", index: 0}
      ]

      assert %{
               content: [
                 %{"type" => "thinking", "thinking" => "Let me think.", "signature" => "sig"}
               ]
             } =
               StreamProcessor.build_final_message(events)
    end
  end
end
