defmodule Normandy.Components.AgentMemory.RepeatedAnswerTest do
  @moduledoc """
  A chat agent's blank final answer can be taken from its tool round's text
  (`BaseAgent`'s tool-round fallback), so memory holds that sentence twice: in the
  tool-calling response and as the final answer. A request shows it once: the
  tool-calling message loses its text blocks. What is stored does not change.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  defmodule City do
    @moduledoc false
    use Normandy.Schema

    io_schema "a city" do
      field(:chat, :string, description: "the city")
    end
  end

  @thinking %{"type" => "thinking", "thinking" => "t", "signature" => "s"}

  defp tool_round(text, opts \\ []) do
    calls = Keyword.get(opts, :calls, [%ToolCall{id: "c1", name: "record_city", input: %{}}])
    thinking = Keyword.get(opts, :thinking, [])

    blocks =
      case Keyword.get(opts, :form, :replay) do
        :rebuilt ->
          []

        :replay ->
          thinking ++
            [%{"type" => "text", "text" => text}] ++
            Enum.map(
              calls,
              &%{"type" => "tool_use", "id" => &1.id, "name" => &1.name, "input" => %{}}
            )
      end

    %ToolCallResponse{
      content: text,
      tool_calls: calls,
      thinking: thinking,
      content_blocks: blocks
    }
  end

  defp result, do: %ToolResult{tool_call_id: "c1", output: "recorded"}
  defp answer(text), do: %BaseAgentOutputSchema{chat_message: text}

  defp memory(messages) do
    Enum.reduce(messages, AgentMemory.new_memory(), fn
      :new_turn, m -> AgentMemory.initialize_turn(m)
      {role, content}, m -> AgentMemory.add_message(m, role, content)
    end)
  end

  defp chain(round, final \\ answer("Paris.")) do
    memory([
      :new_turn,
      {"user", "Capital of France?"},
      {"assistant", round},
      {"tool", result()},
      {"assistant", final},
      :new_turn,
      {"user", "Thanks"}
    ])
  end

  # Every text the model is shown: string contents and text blocks.
  defp texts(messages) do
    Enum.flat_map(messages, fn
      %{content: text} when is_binary(text) -> [text]
      %{content: blocks} when is_list(blocks) -> Enum.flat_map(blocks, &block_text/1)
    end)
  end

  defp block_text(%{type: "text", text: text}), do: [text]
  defp block_text(%{"type" => "text", "text" => text}), do: [text]
  defp block_text(_block), do: []

  defp count(messages, text), do: messages |> texts() |> Enum.count(&(&1 == text))

  defp request(memory), do: AgentMemory.request_messages_for(memory, 1)

  for form <- [:replay, :rebuilt] do
    @form form

    test "#{form}: the tool-calling message loses its text when the answer repeats it" do
      memory = chain(tool_round("Paris.", form: @form))
      messages = request(memory)

      assert Enum.map(messages, & &1.role) == ["user", "assistant", "tool", "assistant", "user"]
      assert count(messages, "Paris.") == 1
      assert [%Message{role: "assistant", content: blocks} | _] = Enum.drop(messages, 1)
      assert blocks != []
      assert Enum.all?(blocks, &((&1[:type] || &1["type"]) == "tool_use"))
      assert %Message{role: "assistant", content: "Paris."} = Enum.at(messages, 3)
    end

    test "#{form}: messages/1 and history/1 still hold the text twice" do
      memory = chain(tool_round("Paris.", form: @form))

      assert count(AgentMemory.history(memory), "Paris.") == 2

      assert [_, %Message{content: %ToolCallResponse{content: "Paris."}}, _, _, _] =
               AgentMemory.messages(memory)
    end
  end

  test "a JSON-wrapped tool-round text equal to the answer is dropped too" do
    memory = chain(tool_round(~s({"chat_message": "Paris."}), form: :rebuilt))
    messages = request(memory)

    assert texts(messages) == ["Capital of France?", "Paris.", "Thanks"]
  end

  test "a server-tool block beside the text stays" do
    server = %{"type" => "server_tool_use", "id" => "s1", "name" => "web_search", "input" => %{}}

    server_result = %{
      "type" => "web_search_tool_result",
      "tool_use_id" => "s1",
      "content" => []
    }

    round = tool_round("Paris.")
    round = %{round | content_blocks: [server, server_result | round.content_blocks]}
    [_, %{content: blocks} | _] = request(chain(round))

    assert [^server, ^server_result, %{"type" => "tool_use"}] = blocks
  end

  test "a cap notice between the tool result and the answer: still dropped" do
    memory =
      memory([
        :new_turn,
        {"user", "Capital of France?"},
        {"assistant", tool_round("Paris.")},
        {"tool", result()},
        {"user", "Tool limit reached; answer now."},
        {"assistant", answer("Paris.")}
      ])

    assert count(request(memory), "Paris.") == 1
  end

  describe "kept as stored" do
    for form <- [:replay, :rebuilt] do
      @form form

      test "#{form}: a tool-calling message with a thinking block" do
        memory = chain(tool_round("Paris.", form: @form, thinking: [@thinking]))
        assert count(request(memory), "Paris.") == 2
      end
    end

    test "a redacted_thinking block" do
      redacted = %{"type" => "redacted_thinking", "data" => "d"}
      memory = chain(tool_round("Paris.", thinking: [redacted]))
      assert count(request(memory), "Paris.") == 2
    end

    test "texts that differ (a guardrail rewrote the answer)" do
      memory = chain(tool_round("Paris."), answer("[redacted]"))
      assert count(request(memory), "Paris.") == 1
      assert count(request(memory), "[redacted]") == 1
      assert [_, %{content: [%{"type" => "text"}, _]} | _] = request(memory)
    end

    test "the tool round is in an earlier turn" do
      memory =
        memory([
          :new_turn,
          {"user", "Capital of France?"},
          {"assistant", tool_round("Paris.")},
          {"tool", result()},
          :new_turn,
          {"user", "Again?"},
          {"assistant", answer("Paris.")}
        ])

      assert count(request(memory), "Paris.") == 2
    end

    test "the response has no tool calls (paused)" do
      paused = %ToolCallResponse{
        content: "Paris.",
        tool_calls: [],
        stop_reason: :pause_turn,
        content_blocks: [%{"type" => "text", "text" => "Paris."}]
      }

      memory =
        memory([
          :new_turn,
          {"user", "Capital of France?"},
          {"assistant", paused},
          {"assistant", answer("Paris.")}
        ])

      assert count(request(memory), "Paris.") == 2
    end

    test "another final answer lies between" do
      memory =
        memory([
          :new_turn,
          {"user", "Capital of France?"},
          {"assistant", tool_round("Paris.")},
          {"tool", result()},
          {"assistant", answer("Final.")},
          {"assistant", answer("Paris.")}
        ])

      assert count(request(memory), "Paris.") == 2
    end

    test "a structured output" do
      memory = chain(tool_round("Paris."), %City{chat: "Paris."})
      assert [_, %{content: [%{"type" => "text"}, _]} | _] = request(memory)
    end
  end

  describe "round trips give the same request" do
    setup do
      memory = chain(tool_round("Paris."))
      %{memory: memory, expected: request(memory)}
    end

    test "dump/1 and load/1", %{memory: memory, expected: expected} do
      assert memory |> AgentMemory.dump() |> AgentMemory.load() |> request() == expected
    end

    test "from_entries/1", %{memory: memory, expected: expected} do
      assert memory |> AgentMemory.entry_chain() |> AgentMemory.from_entries() |> request() ==
               expected
    end

    test "from_entries/1 with a compaction snapshot", %{memory: memory, expected: expected} do
      snapshot = %AgentMemory.Entry{
        id: "snap",
        turn_id: memory.current_turn_id,
        role: "compaction",
        content: AgentMemory.compaction_content(memory)
      }

      assert request(AgentMemory.from_entries([snapshot])) == expected
    end

    test "ConfigTemplate's drop_cache/1 and fill_cache/1", %{memory: memory, expected: expected} do
      assert memory |> AgentMemory.drop_cache() |> request() == expected

      assert memory |> AgentMemory.drop_cache() |> AgentMemory.fill_cache() |> request() ==
               expected
    end
  end
end
