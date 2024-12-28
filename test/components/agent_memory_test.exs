defmodule Components.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory
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
end
