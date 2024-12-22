defmodule Normandy.Components.AgentMemory do

  def new_memory do
    %{}
  end

  def initialize_turn(memory) do
    memory
    |> Map.replace(:current_turn_id, UUID.uuid4())
  end

  def add_message(memory = %{history: history}, message) do
    Map.replace(memory, :history, history)
  end
end
