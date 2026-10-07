defmodule Normandy.Components.AgentMemoryCompactionTest do
  @moduledoc """
  Task 6.2g: `AgentMemory.from_entries/1` applies the last `"compaction"` snapshot entry
  of a stored history, and `compaction_content/1` builds that snapshot.
  """
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry

  defp stored(id, role, content, turn_id \\ "t1"),
    do: %Entry{id: id, turn_id: turn_id, role: role, content: content}

  defp snapshot(id, entries, turn_id \\ "t2"),
    do: stored(id, "compaction", %{version: 1, entries: entries}, turn_id)

  defp chain(memory),
    do:
      memory |> AgentMemory.entry_chain() |> Enum.map(&{&1.id, &1.parent_id, &1.role, &1.content})

  test "the last snapshot's entries, then the entries after it, linked in order" do
    history = [
      stored("u1", "user", "one"),
      stored("a1", "assistant", "first answer"),
      snapshot("c1", [%{id: "s1", turn_id: "t1", role: "user", content: "old summary"}]),
      stored("u2", "user", "two", "t2"),
      snapshot("c2", [
        %{id: "s2", turn_id: "t2", role: "user", content: "summary"},
        %{id: "u2", turn_id: "t2", role: "user", content: "two"}
      ]),
      stored("a2", "assistant", "second answer", "t2")
    ]

    memory = AgentMemory.from_entries(history)

    assert chain(memory) == [
             {"s2", nil, "user", "summary"},
             {"u2", "s2", "user", "two"},
             {"a2", "u2", "assistant", "second answer"}
           ]

    assert memory.head == "a2"
    assert memory.current_turn_id == "t2"
    refute Map.has_key?(memory.entries, "c2")
    refute Map.has_key?(memory.entries, "u1")
  end

  test "a snapshot with nothing after it: its entries, and its turn as the current one" do
    memory =
      AgentMemory.from_entries([
        stored("u1", "user", "one"),
        snapshot("c1", [%{id: "k1", turn_id: "t1", role: "user", content: "one"}], "t9")
      ])

    assert chain(memory) == [{"k1", nil, "user", "one"}]
    assert memory.current_turn_id == "t9"
  end

  test "compaction_content/1 is what from_entries/1 restores" do
    live =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "summary")
      |> AgentMemory.add_message("assistant", %{"answer" => 42})

    restored =
      AgentMemory.from_entries([
        stored("u0", "user", "dropped"),
        snapshot("c1", AgentMemory.compaction_content(live).entries, live.current_turn_id)
      ])

    assert chain(restored) == chain(live)
    assert restored.head == live.head
    assert restored.current_turn_id == live.current_turn_id

    assert %{version: 1, entries: [%{id: _, turn_id: _, role: "user", content: "summary"} | _]} =
             AgentMemory.compaction_content(live)
  end

  test "a snapshot of another version raises, naming it" do
    assert_raise ArgumentError,
                 ~s|AgentMemory.from_entries/1: compaction entry "c1" has snapshot version 2; this Normandy reads version 1|,
                 fn ->
                   AgentMemory.from_entries([
                     stored("c1", "compaction", %{version: 2, entries: []})
                   ])
                 end
  end

  test "a compaction entry that is not a snapshot raises, naming its type" do
    assert_raise ArgumentError,
                 ~s|AgentMemory.from_entries/1: compaction entry "c1" expected content %{version: 1, entries: [...]}, got: a string (6 bytes)|,
                 fn -> AgentMemory.from_entries([stored("c1", "compaction", "secret")]) end
  end
end
