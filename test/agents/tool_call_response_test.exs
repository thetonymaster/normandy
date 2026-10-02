defmodule Normandy.Agents.ToolCallResponseTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.{BaseIOSchema, ToolCall}

  test "to_json sends a refused non-object input as {} so the API accepts the replay" do
    response = %ToolCallResponse{
      content: nil,
      tool_calls: [%ToolCall{id: "t1", name: "weather", input: ~s({"city": "NY)}]
    }

    assert [%{type: "tool_use", id: "t1", input: %{}}] = BaseIOSchema.to_json(response)
  end

  test "to_json sends thinking blocks first, unchanged, then text and tool calls" do
    thinking = %{"type" => "thinking", "thinking" => "check the weather", "signature" => "sig1"}
    redacted = %{"type" => "redacted_thinking", "data" => "opaque"}

    response = %ToolCallResponse{
      thinking: [thinking, redacted],
      content: "Let me look.",
      tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{"city" => "NY"}}]
    }

    assert [^thinking, ^redacted, %{type: "text"}, %{type: "tool_use", id: "t1"}] =
             BaseIOSchema.to_json(response)
  end

  test "to_json keeps an object input" do
    response = %ToolCallResponse{tool_calls: [%ToolCall{id: "t1", name: "w", input: %{"a" => 1}}]}

    assert [%{input: %{"a" => 1}}] = BaseIOSchema.to_json(response)
  end

  test "prefix_key/3 changes with the system prompt, tools or model, not with tool order" do
    a = %{name: "a", input_schema: %{}}
    b = %{name: "b", input_schema: %{}}

    assert ToolCallResponse.prefix_key("sys", [a, b], "m") ==
             ToolCallResponse.prefix_key("sys", [b, a], "m")

    refute ToolCallResponse.prefix_key("sys", [a], "m") ==
             ToolCallResponse.prefix_key("sys2", [a], "m")

    refute ToolCallResponse.prefix_key("sys", [a], "m") ==
             ToolCallResponse.prefix_key("sys", [a, b], "m")

    refute ToolCallResponse.prefix_key("sys", [a], "m") ==
             ToolCallResponse.prefix_key("sys", [a], "other")
  end

  test "to_json does not send prefix_key" do
    response = %ToolCallResponse{prefix_key: 123, content: "hi"}
    assert [%{type: "text", text: "hi"}] = BaseIOSchema.to_json(response)
  end
end
