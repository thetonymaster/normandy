defmodule Normandy.Components.AgentMemory do
  alias Normandy.Components.Message

  def new_memory(max_messages \\ 10) do
    %{max_messages: max_messages, history: [], current_turn_id: nil}
  end

  def initialize_turn(memory = %{current_turn_id: nil}) do
    memory
    |> Map.replace(:current_turn_id, UUID.uuid4())
  end

  def initialize_turn(memory), do: memory

  def add_message(memory, role, content) do
    memory = initialize_turn(memory)
    message = %Message{turn_id: memory.current_turn_id, role: role, content: content}

    max_messages = Map.get(memory, :max_messages, 10)

    history =
      Map.get(memory, :history, [])
      |> Enum.concat([message])
      |> Enum.take(-max_messages)

    Map.put(memory, :history, history)
  end
end
