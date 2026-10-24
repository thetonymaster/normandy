defmodule Normandy.Agents.ToolCallResponseTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Response, as: ClaudioResponse
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.{AgentMemory, BaseIOSchema, ToolCall}

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

  describe "content_blocks" do
    @thinking %{"type" => "thinking", "thinking" => "t", "signature" => "s"}
    @server_use %{
      "type" => "server_tool_use",
      "id" => "s1",
      "name" => "web_search",
      "input" => %{}
    }
    @tool_use %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}

    test "to_json replays them unchanged, in their order" do
      blocks = [@thinking, %{"type" => "text", "text" => "a"}, @server_use, @tool_use]

      response = %ToolCallResponse{
        content: "a",
        thinking: [@thinking],
        tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{}}],
        content_blocks: blocks
      }

      assert BaseIOSchema.to_json(response) == blocks
    end

    test "to_json leaves their thinking out once :thinking is dropped" do
      response = %ToolCallResponse{thinking: [@thinking], content_blocks: [@thinking, @tool_use]}

      assert BaseIOSchema.to_json(AgentMemory.drop_thinking(response)) == [@tool_use]
    end

    test "to_json sends a client tool_use input that is not an object as {}" do
      response = %ToolCallResponse{content_blocks: [%{@tool_use | "input" => ~s({"city": "NY)}]}

      assert [%{"type" => "tool_use", "input" => %{}}] = BaseIOSchema.to_json(response)
    end

    test "a response stored before the field existed is rebuilt from its fields" do
      response =
        %ToolCallResponse{content: "hi"}
        |> Map.delete(:content_blocks)

      assert [%{type: "text", text: "hi"}] = BaseIOSchema.to_json(response)
    end

    test "they survive AgentMemory.dump/1 and load/1" do
      response = %ToolCallResponse{content_blocks: [@thinking, @server_use, @tool_use]}
      memory = AgentMemory.add_message(AgentMemory.new_memory(), "assistant", response)

      assert memory |> AgentMemory.dump() |> AgentMemory.load() |> AgentMemory.history() ==
               AgentMemory.history(memory)
    end

    test "api_blocks/1 is Claudio's replay of the blocks" do
      blocks = [@thinking, %{"type" => "text", "text" => "a", "citations" => nil}, @tool_use]

      assert ToolCallResponse.api_blocks(blocks) ==
               %{"content" => blocks}
               |> ClaudioResponse.from_map()
               |> ClaudioResponse.to_assistant_content()
    end
  end

  test "to_json does not send prefix_key" do
    response = %ToolCallResponse{prefix_key: 123, content: "hi"}
    assert [%{type: "text", text: "hi"}] = BaseIOSchema.to_json(response)
  end
end
