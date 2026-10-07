defmodule Normandy.Components.AgentMemory.RequestMessagesForTest do
  @moduledoc """
  Task 6.1b (PERF-3): `AgentMemory.request_messages_for/2` builds a request's messages in
  one walk from the cached encodings, and gives exactly what
  `drop_stale_thinking/2 |> history/1 |> request_messages/1` gives.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Test.CountingContent

  defp composed(memory, key),
    do:
      memory
      |> AgentMemory.drop_stale_thinking(key)
      |> AgentMemory.history()
      |> AgentMemory.request_messages()

  # ── generators: the shapes Normandy stores ────────────────────────────────────

  defp thinking_gen do
    one_of([
      map({string(:alphanumeric), string(:alphanumeric)}, fn {t, s} ->
        %{"type" => "thinking", "thinking" => t, "signature" => s}
      end),
      map(string(:alphanumeric), &%{"type" => "redacted_thinking", "data" => &1})
    ])
  end

  defp tool_call_gen do
    gen all(
          id <- string(:alphanumeric, min_length: 1),
          input <- one_of([constant(%{"q" => "x"}), constant(%{}), constant("not an object")])
        ) do
      %ToolCall{id: id, name: "lookup", input: input}
    end
  end

  # A response as the adapter stores it: content_blocks in API order (thinking first),
  # or none (built by hand, or stored before the field existed).
  defp tool_call_response_gen do
    gen all(
          thinking <- list_of(thinking_gen(), max_length: 2),
          text <- one_of([constant(nil), constant(""), string(:alphanumeric, min_length: 1)]),
          calls <- list_of(tool_call_gen(), max_length: 2),
          with_blocks? <- boolean(),
          key <- member_of([nil, 1, 2])
        ) do
      blocks =
        if with_blocks?,
          do:
            thinking ++
              if(text in [nil, ""], do: [], else: [%{"type" => "text", "text" => text}]) ++
              Enum.map(
                calls,
                &%{"type" => "tool_use", "id" => &1.id, "name" => "lookup", "input" => &1.input}
              ),
          else: []

      %ToolCallResponse{
        content: text,
        tool_calls: calls,
        thinking: thinking,
        content_blocks: blocks,
        prefix_key: key
      }
    end
  end

  defp entry_gen do
    one_of([
      map(string(:alphanumeric), &{"user", &1}),
      map(tool_call_response_gen(), &{"assistant", &1}),
      map(string(:alphanumeric), &{"tool", %ToolResult{tool_call_id: "c", output: &1}}),
      constant({"tool", %ToolResult{tool_call_id: "c", output: %{"n" => 1}, is_error: true}}),
      map(thinking_gen(), &{"assistant", [&1, %{"type" => "text", "text" => "t"}]}),
      constant({"user", %{"structured" => [1, 2]}})
    ])
  end

  property "drop_thinking/1 of an encoded response equals encoding the response without thinking" do
    check all(response <- tool_call_response_gen()) do
      assert AgentMemory.drop_thinking(BaseIOSchema.to_json(response)) ==
               BaseIOSchema.to_json(AgentMemory.drop_thinking(response))
    end
  end

  property "request_messages_for/2 equals drop_stale_thinking |> history |> request_messages" do
    check all(
            entries <- list_of(entry_gen(), max_length: 12),
            key <- member_of([1, 2])
          ) do
      memory =
        Enum.reduce(entries, AgentMemory.new_memory(), fn {role, content}, m ->
          AgentMemory.add_message(m, role, content)
        end)

      assert AgentMemory.request_messages_for(memory, key) == composed(memory, key)
    end
  end

  test "a stale response's thinking is left out; a later kept one stays" do
    thinking = %{"type" => "thinking", "thinking" => "t", "signature" => "s"}
    stale = %ToolCallResponse{content: "a", thinking: [thinking], prefix_key: 1}
    current = %ToolCallResponse{content: "b", thinking: [thinking], prefix_key: 2}

    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "q")
      |> AgentMemory.add_message("assistant", stale)
      |> AgentMemory.add_message("user", "q2")
      |> AgentMemory.add_message("assistant", current)

    assert [
             %{role: "user", content: "q"},
             %{role: "assistant", content: [%{type: "text", text: "a"}]},
             %{role: "user", content: "q2"},
             %{role: "assistant", content: [^thinking, %{type: "text", text: "b"}]}
           ] = AgentMemory.request_messages_for(memory, 2)
  end

  test "building requests encodes nothing again" do
    ref = CountingContent.counter()

    memory =
      Enum.reduce(1..5, AgentMemory.new_memory(), fn i, m ->
        AgentMemory.add_message(m, "user", CountingContent.new(ref, "m#{i}"))
      end)

    for _ <- 1..10, do: AgentMemory.request_messages_for(memory, 1)

    assert CountingContent.count(ref) == 5
  end
end
