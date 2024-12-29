defmodule Components.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.IOTest
  alias IOTest
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

    result = [%Message{role: "main", content: content_a, turn_id: turn_id}]
    assert history == result

    content_b = %{goodbye: "hello"}
    result = result ++ [%Message{role: "secondary", content: content_b, turn_id: turn_id}]

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
end
