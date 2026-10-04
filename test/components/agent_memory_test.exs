defmodule NormandyTest.Components.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.Message
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias NormandyTest.IOTest
  doctest Normandy.Components.AgentMemory

  test "new_memory builds an empty entry graph" do
    memory = AgentMemory.new_memory(10)

    assert memory.max_messages == 10
    assert memory.entries == %{}
    assert memory.head == nil
    assert memory.current_turn_id == nil
  end

  test "custom memory max_messages" do
    assert AgentMemory.new_memory(20).max_messages == 20
  end

  test "initialize_turn mints a fresh current_turn_id each call" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    turn_id = AgentMemory.get_current_turn_id(memory)
    assert turn_id != nil

    turn_id_after =
      memory |> AgentMemory.initialize_turn() |> AgentMemory.get_current_turn_id()

    assert turn_id != turn_id_after
  end

  test "add_message links each entry to the prior head" do
    memory = AgentMemory.new_memory()
    content_a = %{hello: "goodbye"}
    memory = AgentMemory.add_message(memory, "main", content_a)
    turn_id = AgentMemory.get_current_turn_id(memory)

    assert turn_id != nil
    assert AgentMemory.count_messages(memory) == 1

    assert [%Message{role: "main", content: ^content_a, turn_id: ^turn_id}] =
             AgentMemory.messages(memory)

    content_b = %{goodbye: "hello"}
    memory = AgentMemory.add_message(memory, "secondary", content_b)

    assert [
             %Message{role: "main", content: ^content_a},
             %Message{role: "secondary", content: ^content_b}
           ] = AgentMemory.messages(memory)

    assert AgentMemory.latest_message(memory).role == "secondary"
  end

  test "max_messages overflow keeps only the newest entries" do
    memory = AgentMemory.new_memory(1)
    memory = AgentMemory.add_message(memory, "main", %{hello: "goodbye"})
    memory = AgentMemory.add_message(memory, "secondary", %{goodbye: "hello"})

    assert AgentMemory.count_messages(memory) == 1
    assert [%Message{role: "secondary"}] = AgentMemory.messages(memory)
  end

  describe "max_messages keeps a window the API accepts" do
    defp roles(memory), do: memory |> AgentMemory.messages() |> Enum.map(& &1.role)

    test "the kept window starts at a user message" do
      memory =
        AgentMemory.new_memory(3)
        |> AgentMemory.add_message("user", "u1")
        |> AgentMemory.add_message("assistant", "a1")
        |> AgentMemory.add_message("user", "u2")
        |> AgentMemory.add_message("assistant", "a2")

      assert roles(memory) == ["user", "assistant"]
    end

    test "a tool loop is not cut between a tool_use and its result" do
      memory =
        AgentMemory.new_memory(3)
        |> AgentMemory.add_message("user", "u1")
        |> AgentMemory.add_message("assistant", "a1 tool_use")
        |> AgentMemory.add_message("tool", "t1")
        |> AgentMemory.add_message("assistant", "a2")

      # No user message fits in 3, so the window keeps the whole turn.
      assert roles(memory) == ["user", "assistant", "tool", "assistant"]
    end
  end

  test "history gives the default chat input to the model as its plain text" do
    history =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", %Normandy.Agents.BaseAgentInputSchema{
        chat_message: "My locker number is 4417."
      })
      |> AgentMemory.add_message("assistant", %Normandy.Agents.BaseAgentOutputSchema{
        chat_message: "Noted."
      })
      |> AgentMemory.history()

    assert history == [
             %{role: "user", content: "My locker number is 4417."},
             %{role: "assistant", content: "{\"chat_message\":\"Noted.\"}"}
           ]
  end

  test "history reconstructs the chronological role/content view" do
    content_a = %IOTest{}
    content_b = %IOTest{test_field: "hello there"}

    history =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", content_a)
      |> AgentMemory.add_message("system", content_b)
      |> AgentMemory.history()

    assert history == [
             %{role: "user", content: "{\"test_field\":\"test_value\"}"},
             %{role: "system", content: "{\"test_field\":\"hello there\"}"}
           ]
  end

  test "list-shaped content survives history/1 verbatim" do
    blocks = [
      %{"type" => "text", "text" => "describe this"},
      %{"type" => "image", "source" => %{"type" => "url", "url" => "https://example.com/a.png"}}
    ]

    history =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", blocks)
      |> AgentMemory.history()

    assert history == [%{role: "user", content: blocks}]
  end

  test "get_current_turn_id" do
    memory = AgentMemory.new_memory()
    assert AgentMemory.get_current_turn_id(memory) == nil

    memory = AgentMemory.initialize_turn(memory)
    assert AgentMemory.get_current_turn_id(memory) != nil
  end

  test "count_messages" do
    memory = AgentMemory.new_memory()
    assert AgentMemory.count_messages(memory) == 0

    memory = AgentMemory.add_message(memory, "user", %IOTest{})
    assert AgentMemory.count_messages(memory) == 1
  end

  test "latest_message is nil for empty memory" do
    assert AgentMemory.latest_message(AgentMemory.new_memory()) == nil
  end

  test "dump and load round-trips through the JSON adapter" do
    content_a = %IOTest{}
    content_b = %IOTest{test_field: "hello there"}

    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", content_a)
      |> AgentMemory.add_message("system", content_b)

    loaded = memory |> AgentMemory.dump() |> AgentMemory.load()

    assert AgentMemory.count_messages(loaded) == 2
    assert AgentMemory.get_current_turn_id(memory) == AgentMemory.get_current_turn_id(loaded)
    assert memory.max_messages == loaded.max_messages

    assert AgentMemory.history(loaded) == [
             %{role: "user", content: "{\"test_field\":\"test_value\"}"},
             %{role: "system", content: "{\"test_field\":\"hello there\"}"}
           ]
  end

  test "dump tolerates raw (non-struct) content" do
    memory = AgentMemory.new_memory() |> AgentMemory.add_message("user", %{a: 1})
    loaded = memory |> AgentMemory.dump() |> AgentMemory.load()
    assert AgentMemory.count_messages(loaded) == 1
  end

  test "memory with no limits keeps everything" do
    memory =
      Enum.reduce(1..100, AgentMemory.new_memory(), fn x, mem ->
        AgentMemory.add_message(mem, "user", %IOTest{test_field: "hello #{x}"})
      end)

    assert AgentMemory.count_messages(memory) == 100
  end

  test "memory with limit zero stores nothing" do
    memory = AgentMemory.new_memory(0) |> AgentMemory.add_message("user", %IOTest{})
    assert AgentMemory.count_messages(memory) == 0
  end

  test "turn consistency across initialize_turn" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    turn_id = AgentMemory.get_current_turn_id(memory)
    assert turn_id != nil

    memory =
      memory
      |> AgentMemory.add_message("user", %IOTest{test_field: "hello 1"})
      |> AgentMemory.add_message("user", %IOTest{test_field: "hello 2"})

    assert Enum.all?(AgentMemory.messages(memory), &(&1.turn_id == turn_id))

    memory = AgentMemory.initialize_turn(memory)
    new_turn_id = AgentMemory.get_current_turn_id(memory)
    memory = AgentMemory.add_message(memory, "user", %IOTest{test_field: "hello 3"})

    assert new_turn_id != turn_id
    assert AgentMemory.latest_message(memory).turn_id == new_turn_id
  end

  test "delete_turn splices entries and raises on a missing turn" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    initial_turn_id = AgentMemory.get_current_turn_id(memory)
    memory = AgentMemory.add_message(memory, "user", %IOTest{test_field: "hello"})

    memory = AgentMemory.initialize_turn(memory)
    other_turn_id = AgentMemory.get_current_turn_id(memory)
    memory = AgentMemory.add_message(memory, "user", %IOTest{test_field: "goodbye"})

    assert AgentMemory.count_messages(memory) == 2

    memory = AgentMemory.delete_turn(memory, initial_turn_id)
    assert AgentMemory.count_messages(memory) == 1
    assert AgentMemory.latest_message(memory).turn_id == other_turn_id

    memory = AgentMemory.delete_turn(memory, other_turn_id)
    assert AgentMemory.count_messages(memory) == 0

    assert_raise Normandy.NonExistentTurn, fn ->
      AgentMemory.delete_turn(memory, other_turn_id)
    end
  end

  test "delete_turn re-links survivors around a deleted middle turn" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    memory = AgentMemory.add_message(memory, "user", %{c: "a"})

    memory = AgentMemory.initialize_turn(memory)
    turn_b = AgentMemory.get_current_turn_id(memory)
    memory = AgentMemory.add_message(memory, "assistant", %{c: "b"})

    memory = AgentMemory.initialize_turn(memory)
    turn_c = AgentMemory.get_current_turn_id(memory)
    memory = AgentMemory.add_message(memory, "user", %{c: "c"})

    # Chain is A -> B -> C. Deleting the middle turn B must re-link C's parent to A.
    memory = AgentMemory.delete_turn(memory, turn_b)

    assert AgentMemory.count_messages(memory) == 2
    assert Enum.map(AgentMemory.messages(memory), & &1.content) == [%{c: "a"}, %{c: "c"}]
    assert AgentMemory.latest_message(memory).turn_id == turn_c
  end

  test "dump/load preserves string-keyed (multimodal) raw content verbatim" do
    blocks = [
      %{"type" => "text", "text" => "describe this"},
      %{"type" => "image", "source" => %{"type" => "url", "url" => "https://example.com/a.png"}}
    ]

    memory = AgentMemory.new_memory() |> AgentMemory.add_message("user", blocks)
    loaded = memory |> AgentMemory.dump() |> AgentMemory.load()

    assert loaded |> AgentMemory.messages() |> hd() |> Map.get(:content) == blocks
  end

  test "load does not intern arbitrary content keys (atom-table DoS guard)" do
    # A key that exists nowhere else in the codebase. A blanket `keys: :atoms`
    # decode of an untrusted dump would intern it permanently (atom-table
    # exhaustion vector); a hardened load must leave content keys as strings.
    probe = "cr_dos_guard_probe_key_9f3a"
    memory = AgentMemory.new_memory() |> AgentMemory.add_message("user", %{probe => 1})

    loaded = memory |> AgentMemory.dump() |> AgentMemory.load()

    # Content round-trips verbatim (string key preserved)...
    assert loaded |> AgentMemory.messages() |> hd() |> Map.get(:content) == %{probe => 1}
    # ...and the probe key was never interned.
    assert_raise ArgumentError, fn -> String.to_existing_atom(probe) end
  end

  test "entry_chain terminates on a corrupt parent cycle instead of hanging" do
    # A self-cyclic entry (parent_id == id) — the shape a corrupt dump or a
    # duplicate-id append produces. The walk must terminate, not loop forever.
    entry = %Entry{id: "x", parent_id: "x", turn_id: "t", role: "user", content: %{}}
    memory = %AgentMemory{entries: %{"x" => entry}, head: "x", current_turn_id: "t"}

    # Run under a timeout so a regression fails the test instead of hanging the suite.
    chain = Task.await(Task.async(fn -> AgentMemory.entry_chain(memory) end), 2000)
    assert Enum.map(chain, & &1.id) == ["x"]
  end

  test "from_entries/1 rebuilds a memory whose entry_chain matches the input" do
    alias Normandy.Components.AgentMemory

    m =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "a")
      |> AgentMemory.add_message("assistant", "b")

    entries = AgentMemory.entry_chain(m)
    rebuilt = AgentMemory.from_entries(entries)

    assert AgentMemory.entry_chain(rebuilt) |> Enum.map(& &1.content) == ["a", "b"]
    assert rebuilt.head == m.head
  end

  test "from_entries/1 on [] is an empty memory" do
    alias Normandy.Components.AgentMemory
    assert AgentMemory.from_entries([]) == AgentMemory.new_memory()
  end

  test "delete_turn terminates on a corrupt parent cycle instead of hanging" do
    # Two entries in one turn forming a parent cycle (a <-> b) — the shape a corrupt
    # dump can produce. delete_turn marks both deleted; rewiring survivors must not
    # loop forever walking the cycle.
    a = %Entry{id: "a", parent_id: "b", turn_id: "T", role: "user", content: %{}}
    b = %Entry{id: "b", parent_id: "a", turn_id: "T", role: "assistant", content: %{}}
    c = %Entry{id: "c", parent_id: "a", turn_id: "U", role: "user", content: %{}}

    memory = %AgentMemory{
      entries: %{"a" => a, "b" => b, "c" => c},
      head: "c",
      current_turn_id: "U"
    }

    # Under a timeout so a regression fails the test instead of hanging the suite.
    result = Task.await(Task.async(fn -> AgentMemory.delete_turn(memory, "T") end), 2000)

    # a and b are gone; c survives. Its parent walked up into the cycle, so no
    # surviving ancestor exists -> nil.
    assert AgentMemory.count_messages(result) == 1
    assert AgentMemory.get_entry(result, "c").parent_id == nil
    assert result.head == "c"
  end

  describe "history edits drop the thinking they invalidate" do
    # A thinking block is valid only after the exact history that produced it, so
    # an edit that removes earlier messages must drop the thinking it invalidated.
    @thinking [%{"type" => "thinking", "thinking" => "plan", "signature" => "s"}]

    defp tool_round(memory, id) do
      memory
      |> AgentMemory.add_message("user", "go #{id}")
      |> AgentMemory.add_message("assistant", %ToolCallResponse{
        thinking: @thinking,
        tool_calls: [%ToolCall{id: id, name: "weather", input: %{}}]
      })
      |> AgentMemory.add_message("tool", %ToolResult{tool_call_id: id, output: "x"})
    end

    defp thinking_by_call(memory) do
      for %Message{content: %ToolCallResponse{tool_calls: [call], thinking: t}} <-
            AgentMemory.messages(memory),
          do: {call.id, t}
    end

    test "without an edit, every round keeps its thinking" do
      memory = AgentMemory.new_memory(10) |> tool_round("a") |> tool_round("b")
      assert thinking_by_call(memory) == [{"a", @thinking}, {"b", @thinking}]
    end

    test "a max_messages trim drops the thinking of every kept message" do
      memory = AgentMemory.new_memory(4) |> tool_round("a") |> tool_round("b")
      assert thinking_by_call(memory) == [{"b", []}]
    end

    test "delete_turn drops thinking after the deleted turn and keeps it before" do
      memory = AgentMemory.new_memory()
      memory = tool_round(memory, "a")
      memory = AgentMemory.initialize_turn(memory)
      memory = tool_round(memory, "b")
      second_turn = memory.current_turn_id
      memory = AgentMemory.initialize_turn(memory)
      memory = tool_round(memory, "c")

      memory = AgentMemory.delete_turn(memory, second_turn)

      assert thinking_by_call(memory) == [{"a", @thinking}, {"c", []}]
    end

    test "drop_thinking/1 removes thinking blocks from a block list and a ToolCallResponse" do
      blocks = [
        %{"type" => "thinking", "thinking" => "p", "signature" => "s"},
        %{type: "redacted_thinking", data: "d"},
        %{type: "tool_use", id: "t1", name: "w", input: %{}}
      ]

      assert [%{type: "tool_use"}] = AgentMemory.drop_thinking(blocks)

      assert %ToolCallResponse{thinking: []} =
               AgentMemory.drop_thinking(%ToolCallResponse{thinking: @thinking})

      assert AgentMemory.drop_thinking("text") == "text"
    end
  end

  describe "drop_stale_thinking/2" do
    # A thinking block is valid only under the system prompt and tools it was
    # produced with (prefix_key). Earlier thinking blocks are not part of a block's
    # prefix, so a leading run can go; removing one after a kept block breaks the
    # chain for every later block.
    @t [%{"type" => "thinking", "thinking" => "p", "signature" => "s"}]

    defp stamped(keys) do
      Enum.reduce(Enum.with_index(keys), AgentMemory.new_memory(), fn {key, i}, mem ->
        mem
        |> AgentMemory.add_message("user", "go #{i}")
        |> AgentMemory.add_message("assistant", %ToolCallResponse{
          thinking: @t,
          prefix_key: key,
          tool_calls: [%ToolCall{id: "c#{i}", name: "w", input: %{}}]
        })
        |> AgentMemory.add_message("tool", %ToolResult{tool_call_id: "c#{i}", output: "x"})
      end)
    end

    defp kept(memory) do
      for %Message{content: %ToolCallResponse{thinking: t}} <- AgentMemory.messages(memory),
          do: t != []
    end

    test "blocks produced under the current prefix are kept" do
      assert stamped([1, 1]) |> AgentMemory.drop_stale_thinking(1) |> kept() == [true, true]
    end

    test "a leading run under an old prefix is dropped and later blocks stay" do
      assert stamped([1, 1, 2]) |> AgentMemory.drop_stale_thinking(2) |> kept() ==
               [false, false, true]
    end

    test "a stale block after a kept one drops every later block" do
      assert stamped([2, 1, 2]) |> AgentMemory.drop_stale_thinking(2) |> kept() ==
               [true, false, false]
    end

    test "unstamped blocks (from before prefix_key existed) are left as they are" do
      assert stamped([nil, nil]) |> AgentMemory.drop_stale_thinking(2) |> kept() == [true, true]
    end
  end

  describe "add_message/4" do
    test "id: gives the entry that id instead of a new one" do
      memory = AgentMemory.add_message(AgentMemory.new_memory(), "user", "x", id: "entry-1")

      assert [%Entry{id: "entry-1", content: "x"}] = AgentMemory.entry_chain(memory)
      assert memory.head == "entry-1"
    end

    test "turn_id: stores the message under the given turn, not the current one" do
      memory =
        AgentMemory.new_memory()
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", "old", turn_id: "turn-old")
        |> AgentMemory.add_message("user", "new")

      [old, new] = AgentMemory.messages(memory)
      assert old.turn_id == "turn-old"
      assert new.turn_id == AgentMemory.get_current_turn_id(memory)
      refute new.turn_id == "turn-old"
    end

    test "an unknown option raises" do
      assert_raise ArgumentError, fn ->
        AgentMemory.add_message(AgentMemory.new_memory(), "user", "x", turn: "t")
      end
    end
  end

  describe "dump/load with nested structs" do
    defp tool_turn(answered?) do
      memory =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "go")
        |> AgentMemory.add_message("assistant", %ToolCallResponse{
          content: "",
          tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{"city" => "Lima"}}]
        })

      if answered?,
        do: AgentMemory.add_message(memory, "tool", %ToolResult{tool_call_id: "t1", output: "x"}),
        else: memory
    end

    defp contents(memory), do: memory |> AgentMemory.messages() |> Enum.map(& &1.content)

    test "tool calls inside a ToolCallResponse come back as %ToolCall{} structs" do
      memory = tool_turn(true)
      loaded = memory |> AgentMemory.dump() |> AgentMemory.load()

      assert contents(loaded) == contents(memory)
    end

    test "thinking blocks inside a ToolCallResponse come back unchanged" do
      thinking = [
        %{"type" => "thinking", "thinking" => "plan", "signature" => "sig1"},
        %{"type" => "redacted_thinking", "data" => "opaque"}
      ]

      memory =
        AgentMemory.add_message(AgentMemory.new_memory(), "assistant", %ToolCallResponse{
          thinking: thinking,
          tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{}}]
        })

      assert [%ToolCallResponse{thinking: ^thinking}] =
               memory |> AgentMemory.dump() |> AgentMemory.load() |> contents()
    end

    test "a ToolCallResponse dumped before :thinking existed loads with no thinking" do
      old_dump =
        tool_turn(false)
        |> AgentMemory.dump()
        |> Poison.decode!()
        |> Map.update!("entries", fn entries ->
          Enum.map(entries, fn entry ->
            update_in(entry, ["content", "data"], fn
              data when is_map(data) -> Map.delete(data, "thinking")
              data -> data
            end)
          end)
        end)
        |> Poison.encode!()

      refute old_dump =~ "thinking"

      assert ["go", %ToolCallResponse{thinking: []}] =
               old_dump |> AgentMemory.load() |> contents()
    end

    test "an answered batch stays answered and an open one stays open after a round trip" do
      answered = tool_turn(true) |> AgentMemory.dump() |> AgentMemory.load()
      open = tool_turn(false) |> AgentMemory.dump() |> AgentMemory.load()

      assert Turn.unanswered_tool_calls(AgentMemory.messages(answered)) == []

      assert [%ToolCall{id: "t1", name: "weather"}] =
               Turn.unanswered_tool_calls(AgentMemory.messages(open))
    end

    test "a dump written before nested structs were tagged still loads" do
      legacy =
        Poison.encode!(%{
          version: 1,
          max_messages: nil,
          current_turn_id: "turn",
          head: "e1",
          entries: [
            %{
              id: "e1",
              parent_id: nil,
              turn_id: "turn",
              role: "assistant",
              content: %{
                type: "Elixir.Normandy.Agents.ToolCallResponse",
                data: %{
                  "__meta__" => %{"state" => "built"},
                  "content" => "",
                  "tool_calls" => [%{"id" => "t1", "name" => "weather", "input" => %{}}]
                }
              }
            }
          ]
        })

      assert [%ToolCallResponse{tool_calls: [%{"id" => "t1"}]} = resp] =
               legacy |> AgentMemory.load() |> contents()

      assert resp.__meta__ == %ToolCallResponse{}.__meta__
    end
  end

  describe "dump/load of content blocks and untrusted dumps" do
    alias Normandy.Components.ContentBlock.{Document, Image, Text}

    defp round_trip(content) do
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", content)
      |> AgentMemory.dump()
      |> AgentMemory.load()
      |> AgentMemory.messages()
      |> hd()
      |> Map.get(:content)
    end

    test "a single base64 image comes back usable" do
      image = %Image{source: :base64, data: "aGk=", media_type: "image/png"}

      assert %Image{source: :base64} = loaded = round_trip(image)
      assert Image.to_claudio(loaded) == Image.to_claudio(image)
    end

    test "a multimodal list comes back as the same blocks" do
      blocks = [
        %Text{text: "look"},
        %Image{source: :url, url: "https://example.com/a.png"},
        %Document{source: :file_id, file_id: "file_1"}
      ]

      assert round_trip(blocks) == blocks
    end

    defp dump_naming(type) do
      Poison.encode!(%{
        version: 1,
        max_messages: nil,
        current_turn_id: "t",
        head: "e1",
        entries: [
          %{
            id: "e1",
            parent_id: nil,
            turn_id: "t",
            role: "user",
            content: %{type: type, data: %{}}
          }
        ]
      })
    end

    test "load refuses a struct that is not a Normandy schema" do
      assert_raise ArgumentError, ~r/not a Normandy schema: "Elixir.URI"/, fn ->
        AgentMemory.load(dump_naming("Elixir.URI"))
      end
    end

    test "load refuses a dump version it does not know" do
      dump = Poison.encode!(%{version: 99, entries: []})

      assert_raise ArgumentError, ~r/unsupported dump version 99/, fn ->
        AgentMemory.load(dump)
      end
    end
  end
end
