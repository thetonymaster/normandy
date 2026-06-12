defmodule NormandyTest.Components.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias NormandyTest.IOTest
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
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
end
