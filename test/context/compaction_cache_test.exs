defmodule Normandy.Context.CompactionCacheTest do
  @moduledoc """
  Task 6.1c (PERF-3): compaction reads the entries' cached estimates and rebuilds the
  memory in one pass (`AgentMemory.keep_entries/3`) without encoding a kept message again.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Test.CountingContent
  alias Normandy.Test.MockSummarizerClient

  @thinking %{"type" => "thinking", "thinking" => "t", "signature" => "s"}

  defp counting_memory(ref, n) do
    Enum.reduce(1..n, AgentMemory.initialize_turn(AgentMemory.new_memory()), fn i, m ->
      role = if rem(i, 2) == 1, do: "user", else: "assistant"
      AgentMemory.add_message(m, role, CountingContent.new(ref, "message number #{i} padding"))
    end)
  end

  # What WindowManager and Summarizer did before Task 6.1c: one add_message per kept
  # entry, under its own id and turn, with its thinking dropped.
  defp reference_keep(memory, kept, summary) do
    fresh = %{
      AgentMemory.new_memory(memory.max_messages)
      | current_turn_id: memory.current_turn_id
    }

    fresh =
      case summary do
        nil -> fresh
        {role, content} -> AgentMemory.add_message(fresh, role, content, id: "summary")
      end

    Enum.reduce(kept, fresh, fn entry, mem ->
      AgentMemory.add_message(mem, entry.role, AgentMemory.drop_thinking(entry.content),
        turn_id: entry.turn_id,
        id: entry.id
      )
    end)
  end

  # The summary gets a new UUID; the reference gives it the id "summary". Renames the
  # one entry of `result` that is not one of `memory`'s (if a cap left it in).
  defp rename_summary(result, memory) do
    case Enum.reject(Map.values(result.entries), &Map.has_key?(memory.entries, &1.id)) do
      [] ->
        result

      [summary] ->
        entries =
          result.entries
          |> Map.delete(summary.id)
          |> Map.put("summary", %{summary | id: "summary"})
          |> Map.new(fn
            {id, %Entry{parent_id: parent} = e} when parent == summary.id ->
              {id, %{e | parent_id: "summary"}}

            pair ->
              pair
          end)

        head = if result.head == summary.id, do: "summary", else: result.head
        %{result | entries: entries, head: head}
    end
  end

  defp message_gen do
    one_of([
      map(string(:alphanumeric), &{"user", &1}),
      map(string(:alphanumeric), &{"assistant", &1}),
      constant(
        {"assistant", %ToolCallResponse{content: "c", thinking: [@thinking], prefix_key: 1}}
      ),
      constant({"assistant", [@thinking, %{"type" => "text", "text" => "t"}]})
    ])
  end

  property "keep_entries/3 builds what one add_message per kept entry built" do
    check all(
            messages <- list_of(message_gen(), min_length: 1, max_length: 10),
            keep <- integer(0..10),
            max <- one_of([constant(nil), integer(1..6)]),
            summary <- one_of([constant(nil), constant({"user", "the summary"})])
          ) do
      memory =
        Enum.reduce(messages, AgentMemory.new_memory(), fn {role, content}, m ->
          AgentMemory.add_message(m, role, content)
        end)

      memory = %{memory | max_messages: max}
      kept = memory |> AgentMemory.entry_chain() |> Enum.take(-keep)

      assert rename_summary(AgentMemory.keep_entries(memory, kept, summary: summary), memory) ==
               reference_keep(memory, kept, summary)
    end
  end

  test "keep_entries/3 starts a turn for a memory with none, as add_message/4 does" do
    memory = AgentMemory.add_message(AgentMemory.new_memory(), "user", "q")
    [kept] = AgentMemory.entry_chain(memory)

    result =
      AgentMemory.keep_entries(%{memory | current_turn_id: nil}, [kept], summary: {"user", "s"})

    assert is_binary(result.current_turn_id)

    assert [%Entry{content: "s", turn_id: turn}, %Entry{id: id, turn_id: kept_turn}] =
             AgentMemory.entry_chain(result)

    assert turn == result.current_turn_id
    assert {id, kept_turn} == {kept.id, kept.turn_id}

    assert %AgentMemory{entries: entries, current_turn_id: nil} =
             AgentMemory.keep_entries(%{memory | current_turn_id: nil}, [])

    assert entries == %{}
  end

  test "keep_entries/3 refuses an unknown option" do
    assert_raise ArgumentError,
                 "Normandy.Components.AgentMemory.keep_entries/3: unknown option :sumary; " <>
                   "supported: :summary",
                 fn ->
                   AgentMemory.keep_entries(AgentMemory.new_memory(), [], sumary: {"user", "s"})
                 end
  end

  test "an :oldest_first compaction encodes no kept message again" do
    ref = CountingContent.counter()
    acc = %{memory: counting_memory(ref, 40)}

    {result, meta} =
      WMCompactor.maybe_compact(acc, %{model: "m", window: 120}, reserved_tokens: 16)

    assert meta.compacted
    assert length(AgentMemory.entry_chain(result.memory)) < 40
    assert CountingContent.count(ref) == 40
  end

  test "a :summarize compaction encodes no kept message again (the summary is new text)" do
    ref = CountingContent.counter()

    acc = %{
      memory: counting_memory(ref, 20),
      client: %MockSummarizerClient{summary_response: "a short summary"},
      model: "m"
    }

    {result, meta} =
      WMCompactor.maybe_compact(acc, %{model: "m", window: 200},
        strategy: :summarize,
        reserved_tokens: 64
      )

    assert meta.compacted
    assert [%Entry{wire: "The earlier part" <> _} | _] = AgentMemory.entry_chain(result.memory)
    # The summary request reads history/1 (cached wire); nothing is encoded twice.
    assert CountingContent.count(ref) == 20
  end

  test "a conversation within the window is estimated once and left as it is" do
    ref = CountingContent.counter()
    acc = %{memory: counting_memory(ref, 4)}

    assert {^acc,
            %{
              compacted: false,
              tokens_before: before,
              tokens_after: before,
              tokens_removed: 0,
              strategy: :oldest_first,
              dropped: []
            }} =
             WMCompactor.maybe_compact(acc, %{model: "m", window: 200_000}, reserved_tokens: 16)

    assert before == Normandy.Context.WindowManager.estimate_conversation_tokens(acc.memory)
    assert CountingContent.count(ref) == 4
  end

  test "tokens_removed counts what the model is sent for a chat message, as tokens_before does" do
    memory =
      Enum.reduce(1..10, AgentMemory.initialize_turn(AgentMemory.new_memory()), fn i, m ->
        AgentMemory.add_message(m, "user", %BaseAgentInputSchema{
          chat_message: "this turn message #{i} with padding text"
        })
      end)

    {_acc, meta} =
      WMCompactor.maybe_compact(%{memory: memory}, %{model: "m", window: 80}, reserved_tokens: 16)

    assert meta.compacted
    assert meta.tokens_removed == Enum.sum(Enum.map(meta.dropped, & &1.tokens))
    assert meta.tokens_removed == meta.tokens_before - meta.tokens_after
  end
end
