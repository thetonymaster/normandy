defmodule Components.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  doctest Normandy.Components.AgentMemory

  test "get a new memory" do
    memory = AgentMemory.new_memory()

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

    assert turn_id == turn_id_after
  end

  test "add a new message" do
    memory = AgentMemory.new_memory()
    content_a = %{hello: "goodbye"}
    memory = AgentMemory.add_message(memory, "main", content_a)
    turn_id = Map.get(memory, :current_turn_id)
    history = Map.get(memory, :history)

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
    content_a = %Normandy.IOTest{}
    content_b = %Normandy.IOTest{test_field: "hello there"}

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
end
