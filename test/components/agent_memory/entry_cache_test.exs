defmodule Normandy.Components.AgentMemory.EntryCacheTest do
  @moduledoc """
  Task 6.1a (PERF-3): an entry's model-facing encoding (`wire`) and token estimate
  (`tokens`) are computed once, when its content is set, and every reader uses them.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Components.ToolCall
  alias Normandy.Context.WindowManager
  alias Normandy.Test.CountingContent

  defmodule NoEncoding do
    @moduledoc false
    defstruct [:value]
  end

  @thinking %{"type" => "thinking", "thinking" => "t", "signature" => "s"}

  defp tool_response(prefix_key) do
    %ToolCallResponse{
      content: "calling",
      tool_calls: [%ToolCall{id: "c1", name: "lookup", input: %{"q" => "x"}}],
      thinking: [@thinking],
      prefix_key: prefix_key
    }
  end

  # Every entry's cache is what encoding its content gives now.
  defp assert_cache_consistent(memory) do
    for {_id, entry} <- AgentMemory.entries(memory) do
      wire = BaseIOSchema.to_json(entry.content)
      assert entry.wire == wire
      assert entry.tokens == WindowManager.estimate_message_content_tokens(wire) + 10
    end
  end

  test "an append encodes the content once; history/1 and the estimate read the cache" do
    ref = CountingContent.counter()

    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", CountingContent.new(ref, "hello there"))
      |> AgentMemory.add_message("assistant", %{"answer" => 42})

    assert CountingContent.count(ref) == 1

    for _ <- 1..3 do
      assert [
               %{role: "user", content: "hello there"},
               %{role: "assistant", content: ~s({"answer":42})}
             ] =
               AgentMemory.history(memory)

      assert WindowManager.estimate_conversation_tokens(memory) ==
               WindowManager.estimate_tokens("hello there") + 10 +
                 WindowManager.estimate_tokens(~s({"answer":42})) + 10
    end

    assert CountingContent.count(ref) == 1
    assert_cache_consistent(memory)
  end

  test "the chat schemas' cached wire is their text, as history/1 sent before" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", %Normandy.Agents.BaseAgentInputSchema{chat_message: "hi"})
      |> AgentMemory.add_message("assistant", %Normandy.Agents.BaseAgentOutputSchema{
        chat_message: "hello"
      })

    assert [%Entry{wire: "hi", tokens: 11}, %Entry{wire: "hello", tokens: 11}] =
             AgentMemory.entry_chain(memory)
  end

  test "content that cannot be encoded raises at the append" do
    assert_raise Protocol.UndefinedError, fn ->
      AgentMemory.add_message(AgentMemory.new_memory(), "user", %NoEncoding{value: 1})
    end
  end

  test "dropping stale thinking, deleting a turn and a max_messages trim keep the cache" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "q1")
      |> AgentMemory.add_message("assistant", tool_response(1))
      |> AgentMemory.initialize_turn()
      |> AgentMemory.add_message("user", "q2")
      |> AgentMemory.add_message("assistant", tool_response(1))

    dropped = AgentMemory.drop_stale_thinking(memory, 2)
    assert_cache_consistent(dropped)
    refute Enum.any?(AgentMemory.history(dropped), &match?(%{content: [@thinking | _]}, &1))

    [first | _] = AgentMemory.entry_chain(memory)
    deleted = AgentMemory.delete_turn(memory, first.turn_id)
    assert_cache_consistent(deleted)

    trimmed = AgentMemory.add_message(%{memory | max_messages: 2}, "user", "q3")
    assert_cache_consistent(trimmed)
  end

  test "an entry without thinking keeps its cached term through a trim (nothing re-encoded)" do
    ref = CountingContent.counter()

    memory =
      Enum.reduce(1..4, AgentMemory.new_memory(2), fn i, m ->
        AgentMemory.add_message(m, "user", CountingContent.new(ref, "m#{i}"))
      end)

    assert CountingContent.count(ref) == 4
    assert [%Entry{wire: "m3"}, %Entry{wire: "m4"}] = AgentMemory.entry_chain(memory)
  end

  test "from_entries/1 fills the cache of stored entries, including pre-field terms" do
    stored = %Entry{id: "e1", parent_id: nil, turn_id: "t", role: "user", content: %{"a" => 1}}
    # A term decoded from a template written before :wire and :tokens existed.
    old_shape =
      Map.drop(
        %Entry{id: "e2", parent_id: "e1", turn_id: "t", role: "assistant", content: "ok"},
        [:wire, :tokens]
      )

    memory = AgentMemory.from_entries([stored, old_shape])

    assert [%Entry{id: "e1", wire: ~s({"a":1})}, %Entry{id: "e2", wire: "ok", tokens: 11}] =
             AgentMemory.entry_chain(memory)

    assert_cache_consistent(memory)
  end

  test "dump/1 never writes the cache; load/1 computes it" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "q")
      |> AgentMemory.add_message("assistant", tool_response(nil))

    dump = AgentMemory.dump(memory)

    for entry <- Jason.decode!(dump)["entries"] do
      assert Map.keys(entry) |> Enum.sort() == ~w(content id parent_id role turn_id)
    end

    loaded = AgentMemory.load(dump)
    assert_cache_consistent(loaded)
    assert AgentMemory.history(loaded) == AgentMemory.history(memory)
  end

  test "a hand-built entry with no cache is encoded when read" do
    entry = %Entry{id: "e1", parent_id: nil, turn_id: "t", role: "user", content: %{"k" => "v"}}
    memory = %AgentMemory{entries: %{"e1" => entry}, head: "e1", current_turn_id: "t"}

    assert AgentMemory.history(memory) == [%{role: "user", content: ~s({"k":"v"})}]

    assert WindowManager.estimate_conversation_tokens(memory) ==
             WindowManager.estimate_tokens(~s({"k":"v"})) + 10
  end

  test "drop_cache/1 clears every entry's cache and fill_cache/1 restores it" do
    memory = AgentMemory.add_message(AgentMemory.new_memory(), "user", %{"a" => 1})
    bare = AgentMemory.drop_cache(memory)

    assert [%Entry{wire: nil, tokens: nil}] = AgentMemory.entry_chain(bare)
    assert AgentMemory.fill_cache(bare) == memory
  end
end
