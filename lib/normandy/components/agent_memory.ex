defmodule Normandy.Components.AgentMemory do
  @moduledoc """
  Manages conversation memory for agents with support for turn-based tracking
  and optional message limits.
  """

  alias Normandy.Components.Message
  alias Normandy.Components.BaseIOSchema

  @type t :: %{
          max_messages: pos_integer() | nil,
          history: [Message.t()],
          current_turn_id: String.t() | nil
        }

  @spec new_memory(pos_integer() | nil) :: t()
  def new_memory(max_messages \\ nil) do
    %{max_messages: max_messages, history: [], current_turn_id: nil}
  end

  @spec initialize_turn(t()) :: t()
  def initialize_turn(memory), do: memory |> Map.replace(:current_turn_id, UUID.uuid4())

  @spec add_message(t(), String.t(), struct()) :: t()
  def add_message(memory, role, content) do
    memory =
      if Map.get(memory, :current_turn_id) == nil do
        initialize_turn(memory)
      else
        memory
      end

    message = %Message{turn_id: memory.current_turn_id, role: role, content: content}

    max_messages = Map.get(memory, :max_messages)

    # Prepend message for O(1) operation, reversed when reading history
    history =
      [message | Map.get(memory, :history, [])]
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
    # Take from front since we prepend messages
    Enum.take(history, max_messages)
  end

  @spec history(t()) :: [%{role: String.t(), content: String.t()}]
  def history(%{history: history}) do
    # Reverse since messages are stored in reverse order (newest first)
    # Then map to create the history format
    history
    |> Enum.reverse()
    |> Enum.map(&process_message(&1.role, &1.content))
  end

  defp process_message(role, content) do
    %{role: role, content: BaseIOSchema.to_json(content)}
  end

  @spec get_current_turn_id(t()) :: String.t() | nil
  def get_current_turn_id(memory), do: Map.get(memory, :current_turn_id)

  @spec count_messages(t()) :: non_neg_integer()
  def count_messages(memory), do: Map.get(memory, :history) |> length()

  @spec dump(t()) :: String.t()
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

  @spec load(String.t()) :: t()
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

  @spec delete_turn(t(), String.t()) :: t()
  def delete_turn(memory, turn_id) do
    before_len = length(memory.history)
    history = Enum.reject(memory.history, fn x -> x.turn_id == turn_id end)

    after_len = length(history)

    if before_len == after_len do
      raise Normandy.NonExistentTurn, value: turn_id
    end

    Map.put(memory, :history, history)
  end
end
