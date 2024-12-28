defmodule Normandy.Components.AgentMemory do
  alias Normandy.Components.Message
  alias Normandy.Components.BaseIOSchema

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

  def history(%{history: history}) do
    create_history(history)
  end

  defp create_history(history), do: create_history(history, [])
  defp create_history([], history), do: history

  defp create_history([%{role: role, content: content} | tail], history) do
    message = process_message(role, content)
    history = history ++ [message]
    create_history(tail, history)
  end

  defp process_message(role, content) do
    %{role: role, content: BaseIOSchema.to_json(content)}
  end
end
