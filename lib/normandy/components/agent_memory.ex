defmodule Normandy.Components.AgentMemory do
  alias Normandy.Components.Message
  alias Normandy.Components.BaseIOSchema

  def new_memory(max_messages \\ nil) do
    %{max_messages: max_messages, history: [], current_turn_id: nil}
  end

  def initialize_turn(memory), do: memory |> Map.replace(:current_turn_id, UUID.uuid4())

  def add_message(memory, role, content) do
    memory =
      if Map.get(memory, :current_turn_id) == nil do
        initialize_turn(memory)
      else
        memory
      end

    message = %Message{turn_id: memory.current_turn_id, role: role, content: content}

    max_messages = Map.get(memory, :max_messages)

    history =
      Map.get(memory, :history, [])
      |> Enum.concat([message])
      |> manage_overflow(max_messages)

    Map.put(memory, :history, history)
  end

  defp manage_overflow(history, nil) do
    history
  end

  defp manage_overflow(_, 0) do
    []
  end

  defp manage_overflow(history, max_messages) do
    Enum.take(history, -max_messages)
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

  def get_current_turn_id(memory), do: Map.get(memory, :current_turn_id)

  def count_messages(memory), do: Map.get(memory, :history) |> length()

  def dump(memory) do
    max_messages = Map.get(memory, :max_messages)
    history = Map.get(memory, :history)
    turn_id = Map.get(memory, :current_turn_id)

    adapter = Application.get_env(:normandy, :adapter)

    serialized_history =
      for %Message{turn_id: turn_id, role: role, content: content} <- history do
        %{
          turn_id: turn_id,
          role: role,
          content: %{type: to_string(content.__struct__), data: content}
        }
      end

    adapter.encode!(%{
      max_messages: max_messages,
      current_turn_id: turn_id,
      history: serialized_history
    })
  end

  def load(dump) do
    adapter = Application.get_env(:normandy, :adapter)
    loaded_memory = adapter.decode!(dump, keys: :atoms)

    max_messages = Map.get(loaded_memory, :max_messages)
    messages = Map.get(loaded_memory, :history)
    turn_id = Map.get(loaded_memory, :current_turn_id)

    history = load_messages(messages)
    %{current_turn_id: turn_id, max_messages: max_messages, history: history}
  end

  defp load_messages(messages), do: load_messages(messages, [])
  defp load_messages([], history), do: history

  defp load_messages([message | tail], history) do
    %{
      content: %{type: type, data: data}
    } = message

    mod = String.to_existing_atom(type)
    content = struct(mod, data)

    loaded_message = %Message{
      turn_id: message.turn_id,
      role: message.role,
      content: content
    }

    history = history ++ [loaded_message]
    load_messages(tail, history)
  end

  def delete_turn(memory, turn_id) do
    before_len = length(memory.history)
    history = Enum.reject(memory.history, fn x -> x.turn_id == turn_id end)

    after_len = length(history)

    if before_len == after_len do
      raise Normandy.NonExistantTurn, [value: turn_id]
    end

    Map.put(memory, :history, history)

  end
end
