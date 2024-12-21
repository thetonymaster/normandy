defmodule Normandy.Components.AgentMemory do
  alias Normandy.Schemas.MemoryConfig

  def new_memory do
    %MemoryConfig{}
  end

  @spec initialize_turn(MemoryConfig.t()) :: MemoryConfig.t()
  def initialize_turn(memory) do
    memory
    |> Map.replace(:current_turn_id, UUID.uuid4())
  end

  @spec add_message(MemoryConfig.t(), any()) :: map()
  def add_message(memory = %MemoryConfig{history: history}, message) do
    Map.replace(memory, :history, history)
  end
end
