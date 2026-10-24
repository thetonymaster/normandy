defmodule Normandy.Components.AgentMemory.RequestMessagesServerToolTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message

  @text_a %{"type" => "text", "text" => "Checking."}
  @text_b %{"type" => "text", "text" => "One more."}
  @answered %{"type" => "mcp_tool_use", "id" => "m1", "name" => "t", "input" => %{}}
  @answer %{"type" => "mcp_tool_result", "tool_use_id" => "m1", "content" => []}
  @dangling %{"type" => "mcp_tool_use", "id" => "m2", "name" => "t", "input" => %{}}
  @dangling_server %{
    "type" => "server_tool_use",
    "id" => "s2",
    "name" => "web_search",
    "input" => %{}
  }

  defp paused(blocks),
    do: %ToolCallResponse{content: "", stop_reason: :pause_turn, content_blocks: blocks}

  defp request_messages(memory),
    do: memory |> AgentMemory.history() |> AgentMemory.request_messages()

  defp conversation(response) do
    AgentMemory.new_memory()
    |> AgentMemory.add_message("user", "q")
    |> AgentMemory.add_message("assistant", response)
  end

  test "a non-last paused message keeps its answered pair and texts, loses the unanswered mcp use" do
    messages =
      paused([@text_a, @answered, @answer, @text_b, @dangling])
      |> conversation()
      |> AgentMemory.add_message("assistant", "answer")
      |> AgentMemory.add_message("user", "next")
      |> request_messages()

    assert [_, %Message{role: "assistant", content: blocks}, _, _] = messages
    assert blocks == [@text_a, @answered, @answer, @text_b]
  end

  test "an unanswered server_tool_use is dropped too" do
    messages =
      paused([@text_a, @dangling_server])
      |> conversation()
      |> AgentMemory.add_message("assistant", "answer")
      |> request_messages()

    assert [_, %Message{role: "assistant", content: [@text_a]}, _] = messages
  end

  test "the last message is sent unchanged" do
    blocks = [@text_a, @answered, @answer, @text_b, @dangling]
    messages = paused(blocks) |> conversation() |> request_messages()

    assert [_, %Message{role: "assistant", content: ^blocks}] = messages
  end

  test "a non-last message left with no blocks is dropped" do
    messages =
      paused([@dangling])
      |> conversation()
      |> AgentMemory.add_message("assistant", "answer")
      |> request_messages()

    assert [%Message{role: "user"}, %Message{role: "assistant", content: "answer"}] = messages
  end

  @use_y %{"type" => "mcp_tool_use", "id" => "m3", "name" => "t", "input" => %{}}
  @answer_x %{"type" => "mcp_tool_result", "tool_use_id" => "m2", "content" => []}

  test "a use answered by the next stored assistant message is kept; the new unanswered one goes" do
    messages =
      paused([@text_a, @dangling])
      |> conversation()
      |> AgentMemory.add_message("assistant", paused([@answer_x, @text_b, @use_y]))
      |> AgentMemory.add_message("assistant", "answer")
      |> AgentMemory.add_message("user", "next")
      |> request_messages()

    assert [_, %Message{content: first}, %Message{content: second}, _, _] = messages
    assert first == [@text_a, @dangling]
    assert second == [@answer_x, @text_b]
  end

  test "a use answered in a later message that also calls a client tool is kept" do
    tool_use = %{"type" => "tool_use", "id" => "T", "name" => "c", "input" => %{}}

    messages =
      paused([@dangling])
      |> conversation()
      |> AgentMemory.add_message("assistant", paused([@answer_x, tool_use]))
      |> AgentMemory.add_message("user", "next")
      |> request_messages()

    assert [_, %Message{content: [@dangling]}, %Message{content: [@answer_x, ^tool_use]}, _] =
             messages
  end

  @thinking %{"type" => "thinking", "thinking" => "hm", "signature" => "sig"}
  @redacted %{"type" => "redacted_thinking", "data" => "xx"}

  defp history(blocks) do
    [
      %{role: "user", content: "q"},
      %{role: "assistant", content: blocks},
      %{role: "assistant", content: "answer"},
      %{role: "user", content: "next"}
    ]
  end

  test "a non-last message the trim leaves with only thinking blocks is dropped" do
    messages = AgentMemory.request_messages(history([@thinking, @redacted, @dangling]))

    assert [%Message{role: "user", content: "q"}, %Message{content: "answer"}, _] = messages
  end

  test "a thinking-only message the trim did not change is kept" do
    messages = AgentMemory.request_messages(history([@thinking, @redacted]))

    assert [_, %Message{content: [@thinking, @redacted]}, _, _] = messages
  end

  test "thinking beside the answered pair and a text survives the trim" do
    messages = AgentMemory.request_messages(history([@thinking, @answered, @answer, @dangling]))

    assert [_, %Message{content: [@thinking, @answered, @answer]}, _, _] = messages
  end
end
