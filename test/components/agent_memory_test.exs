defmodule NormandyTest.Components.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias NormandyTest.IOTest
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  doctest Normandy.Components.AgentMemory

  test "get a new memory" do
    memory = AgentMemory.new_memory(10)

    assert Map.get(memory, :max_messages) == 10
    assert Map.get(memory, :history) == []
    assert Map.get(memory, :current_turn_id) == nil
  end

  test "custom memory max_messages" do
    memory = AgentMemory.new_memory(20)

    assert Map.get(memory, :max_messages) == 20
  end

  test "initialize turn id" do
    memory = AgentMemory.new_memory()

    memory =
      memory
      |> AgentMemory.initialize_turn()

    turn_id = Map.get(memory, :current_turn_id)

    assert turn_id != nil

    turn_id_after =
      memory
      |> AgentMemory.initialize_turn()
      |> Map.get(:current_turn_id)

    assert turn_id != turn_id_after
  end

  test "add a new message" do
    memory = AgentMemory.new_memory()
    content_a = %{hello: "goodbye"}
    memory = AgentMemory.add_message(memory, "main", content_a)
    turn_id = Map.get(memory, :current_turn_id)
    history = Map.get(memory, :history)

    assert turn_id != nil

    # History is stored in reverse order (newest first)
    result = [%Message{role: "main", content: content_a, turn_id: turn_id}]
    assert history == result

    content_b = %{goodbye: "hello"}
    # When stored, newest message is first in the list
    result = [%Message{role: "secondary", content: content_b, turn_id: turn_id} | result]

    history =
      AgentMemory.add_message(memory, "secondary", content_b)
      |> Map.get(:history)

    assert history == result
  end

  test "memory overflow" do
    memory = AgentMemory.new_memory(1)
    content_a = %{hello: "goodbye"}
    memory = AgentMemory.add_message(memory, "main", content_a)
    turn_id = Map.get(memory, :current_turn_id)
    history = Map.get(memory, :history)

    result = [%Message{role: "main", content: content_a, turn_id: turn_id}]
    assert history == result

    content_b = %{goodbye: "hello"}
    # With max_messages=1, only the newest message is kept
    result = [%Message{role: "secondary", content: content_b, turn_id: turn_id}]

    history =
      AgentMemory.add_message(memory, "secondary", content_b)
      |> Map.get(:history)

    assert history == result
  end

  test "get history" do
    content_a = %IOTest{}
    content_b = %IOTest{test_field: "hello there"}

    history =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", content_a)
      |> AgentMemory.add_message("system", content_b)
      |> AgentMemory.history()

    assert length(history) == 2

    assert history == [
             %{role: "user", content: "{\"test_field\":\"test_value\"}"},
             %{role: "system", content: "{\"test_field\":\"hello there\"}"}
           ]
  end

  test "get current turn" do
    memory = AgentMemory.new_memory()
    assert AgentMemory.get_current_turn_id(memory) == nil

    memory = AgentMemory.initialize_turn(memory)
    assert AgentMemory.get_current_turn_id(memory) != nil
  end

  test "get count" do
    memory = AgentMemory.new_memory()

    assert AgentMemory.count_messages(memory) == 0

    content_a = %IOTest{}
    memory = AgentMemory.add_message(memory, "user", content_a)

    assert AgentMemory.count_messages(memory) == 1
  end

  test "dump and load" do
    content_a = %IOTest{}
    content_b = %IOTest{test_field: "hello there"}

    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", content_a)
      |> AgentMemory.add_message("system", content_b)

    dump = AgentMemory.dump(memory)
    loaded_memory = AgentMemory.load(dump)

    assert AgentMemory.count_messages(loaded_memory) == 2

    history = AgentMemory.history(loaded_memory)

    assert AgentMemory.get_current_turn_id(memory) ==
             AgentMemory.get_current_turn_id(loaded_memory)

    assert Map.get(memory, :max_messages) == Map.get(loaded_memory, :max_messages)

    assert history == [
             %{role: "user", content: "{\"test_field\":\"test_value\"}"},
             %{role: "system", content: "{\"test_field\":\"hello there\"}"}
           ]
  end

  test "memory with no limits" do
    memory = AgentMemory.new_memory()

    {_, result} =
      Enum.map_reduce(1..100, memory, fn x, memory ->
        result = AgentMemory.add_message(memory, "user", %IOTest{test_field: "hello #{x}"})
        {memory, result}
      end)

    size = AgentMemory.count_messages(result)

    assert size == 100
  end

  test "memory with limit zero" do
    memory = AgentMemory.new_memory(0)

    memory = AgentMemory.add_message(memory, "user", %IOTest{})

    size = AgentMemory.count_messages(memory)

    assert size == 0
  end

  test "turn consistency" do
    memory = AgentMemory.new_memory()
    memory = memory |> AgentMemory.initialize_turn()
    turn_id = memory |> AgentMemory.get_current_turn_id()

    assert turn_id != nil

    memory =
      memory
      |> AgentMemory.add_message("user", %IOTest{test_field: "hello 1"})
      |> AgentMemory.add_message("user", %IOTest{test_field: "hello 2"})

    history = memory.history

    # History stored in reverse, so index 0 is newest (hello 2), index 1 is older (hello 1)
    assert Enum.at(history, 0).turn_id == turn_id
    assert Enum.at(history, 1).turn_id == turn_id

    memory = memory |> AgentMemory.initialize_turn()
    new_turn_id = memory |> AgentMemory.get_current_turn_id()

    memory =
      memory
      |> AgentMemory.add_message("user", %IOTest{test_field: "hello 3"})

    history = memory.history

    assert new_turn_id != turn_id
    # Index 0 is newest (hello 3) with new_turn_id
    assert Enum.at(history, 0).turn_id == new_turn_id
  end

  test "delete turn" do
    initial_turn_id = "14c35357-c5cc-4f76-920f-b5ed17d3e832"
    other_turn_id = "d1cf623c-61b7-4478-b74c-8bae84ca73ac"

    test_message_a = %IOTest{test_field: "hello"}
    test_message_b = %IOTest{test_field: "goodbye"}

    memory =
      %{
        history: [
          %Message{
            turn_id: initial_turn_id,
            content: test_message_a,
            role: "user"
          },
          %Message{
            turn_id: other_turn_id,
            content: test_message_b,
            role: "user"
          }
        ]
      }

    assert AgentMemory.count_messages(memory) == 2

    memory = memory |> AgentMemory.delete_turn(initial_turn_id)

    assert AgentMemory.count_messages(memory) == 1
    assert Enum.at(memory.history, 0).turn_id == other_turn_id

    memory = memory |> AgentMemory.delete_turn(other_turn_id)

    assert AgentMemory.count_messages(memory) == 0

    assert_raise Normandy.NonExistentTurn,
                 "turn \"d1cf623c-61b7-4478-b74c-8bae84ca73ac\" does not exist",
                 fn ->
                   AgentMemory.delete_turn(memory, other_turn_id)
                 end
  end
end
