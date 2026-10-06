defmodule Normandy.Components.AgentMemory.RequestMessagesUserTextTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Components.ToolResult

  defp result(id), do: %ToolResult{tool_call_id: id, output: "ok #{id}", is_error: false}

  defp request_messages(memory),
    do: memory |> AgentMemory.history() |> AgentMemory.request_messages()

  test "a user text after a tool-result run becomes that message's last block" do
    messages =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "hi")
      |> AgentMemory.add_message("tool", result("t1"))
      |> AgentMemory.add_message("tool", result("t2"))
      |> AgentMemory.add_message("user", "notice")
      |> request_messages()

    assert [%Message{role: "user", content: "hi"}, %Message{role: "tool", content: blocks}] =
             messages

    assert [
             %{type: "tool_result", tool_use_id: "t1"},
             %{type: "tool_result", tool_use_id: "t2"},
             %{type: "text", text: "notice"}
           ] = blocks
  end

  test "two user texts after the run both join it, in order" do
    [_user, %Message{role: "tool", content: blocks}] =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "hi")
      |> AgentMemory.add_message("tool", result("t1"))
      |> AgentMemory.add_message("user", "notice")
      |> AgentMemory.add_message("user", "remember: metric")
      |> request_messages()

    assert [_result, %{type: "text", text: "notice"}, %{type: "text", text: "remember: metric"}] =
             blocks
  end

  test "a user text with no tool results before it stays its own message" do
    assert [%Message{role: "user", content: "a"}, %Message{role: "user", content: "b"}] =
             AgentMemory.new_memory()
             |> AgentMemory.add_message("user", "a")
             |> AgentMemory.add_message("user", "b")
             |> request_messages()
  end

  test "an empty user text is not folded (the API rejects an empty text block)" do
    assert [
             _user,
             %Message{role: "tool", content: [_result]},
             %Message{role: "user", content: ""}
           ] =
             AgentMemory.new_memory()
             |> AgentMemory.add_message("user", "hi")
             |> AgentMemory.add_message("tool", result("t1"))
             |> AgentMemory.add_message("user", "")
             |> request_messages()
  end
end
