defmodule Normandy.Components.AgentMemory do
  def new_memory(max_messages \\ 10) do
    %{max_messages: max_messages, history: [], current_turn_id: nil}
  end

  def initialize_turn(memory) do
    memory
    |> Map.replace(:current_turn_id, UUID.uuid4())
  end

  def add_message(memory = %{history: history}, message) do
    Map.replace(memory, :history, history)
  end
end
