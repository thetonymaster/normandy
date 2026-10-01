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

  test "to_json keeps an object input" do
    response = %ToolCallResponse{tool_calls: [%ToolCall{id: "t1", name: "w", input: %{"a" => 1}}]}

    assert [%{input: %{"a" => 1}}] = BaseIOSchema.to_json(response)
  end
end
