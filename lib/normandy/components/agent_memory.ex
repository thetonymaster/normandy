defmodule Normandy.Components.AgentMemory do
  @moduledoc """
  Conversation memory as a graph of parent-linked entries.

  Each message is an `AgentMemory.Entry` carrying its own `id` and a `parent_id`
  link to the prior entry on its branch. A linear conversation is a degenerate
  single-parent chain: `head` points at the most-recent entry, and walking
  `parent_id` back to a root reproduces the conversation. Branching is opt-in via
  `fork/2`.

  `history/1` reconstructs the active branch in chronological order — output
  identical to the previous linear implementation.
  """

  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.Message
  alias Normandy.Components.BaseIOSchema

  defstruct entries: %{}, head: nil, current_turn_id: nil, max_messages: nil

  @type t :: %__MODULE__{
          entries: %{String.t() => Entry.t()},
          head: String.t() | nil,
          current_turn_id: String.t() | nil,
          max_messages: pos_integer() | nil
        }

  @spec new_memory(pos_integer() | nil) :: t()
  def new_memory(max_messages \\ nil) do
    %__MODULE__{entries: %{}, head: nil, current_turn_id: nil, max_messages: max_messages}
  end

  @spec initialize_turn(t()) :: t()
  def initialize_turn(%__MODULE__{} = memory) do
    %{memory | current_turn_id: UUID.uuid4()}
  end

  @spec get_current_turn_id(t()) :: String.t() | nil
  def get_current_turn_id(%__MODULE__{current_turn_id: id}), do: id

  @spec add_message(t(), String.t(), term()) :: t()
  def add_message(%__MODULE__{} = memory, role, content) do
    memory = if memory.current_turn_id == nil, do: initialize_turn(memory), else: memory

    id = UUID.uuid4()

    entry = %Entry{
      id: id,
      parent_id: memory.head,
      turn_id: memory.current_turn_id,
      role: role,
      content: content
    }

    %{memory | entries: Map.put(memory.entries, id, entry), head: id}
    |> enforce_max_messages()
  end

  @doc "The active branch `head -> root`, returned chronological (oldest -> newest)."
  @spec entry_chain(t()) :: [Entry.t()]
  def entry_chain(%__MODULE__{} = memory) do
    memory |> chain_newest_first() |> Enum.reverse()
  end

  @doc "The active branch as `%Message{}` structs, chronological."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{} = memory) do
    memory |> entry_chain() |> Enum.map(&entry_to_message/1)
  end

  @doc "The newest message (the `head` entry), or nil when empty."
  @spec latest_message(t()) :: Message.t() | nil
  def latest_message(%__MODULE__{head: nil}), do: nil

  def latest_message(%__MODULE__{head: head, entries: entries}) do
    case Map.get(entries, head) do
      nil -> nil
      %Entry{} = entry -> entry_to_message(entry)
    end
  end

  @spec history(t()) :: [%{role: String.t(), content: String.t() | list()}]
  def history(%__MODULE__{} = memory) do
    memory
    |> messages()
    |> Enum.map(fn %Message{role: role, content: content} ->
      %{role: role, content: BaseIOSchema.to_json(content)}
    end)
  end

  @doc """
  Total number of stored entries across all branches (`map_size(entries)`).

  For a linear conversation this equals the active-chain length; after a `fork/2`
  with divergent appends it counts entries on every branch, not just the active one.
  """
  @spec count_messages(t()) :: non_neg_integer()
  def count_messages(%__MODULE__{entries: entries}), do: map_size(entries)

  @doc "Move `head` to `from_entry_id`; subsequent appends branch from there."
  @spec fork(t(), String.t()) :: {:ok, t()} | {:error, :no_such_entry}
  def fork(%__MODULE__{} = memory, from_entry_id) do
    case Map.get(memory.entries, from_entry_id) do
      nil -> {:error, :no_such_entry}
      %Entry{} -> {:ok, %{memory | head: from_entry_id}}
    end
  end

  @spec entries(t()) :: %{String.t() => Entry.t()}
  def entries(%__MODULE__{entries: entries}), do: entries

  @spec get_entry(t(), String.t()) :: Entry.t() | nil
  def get_entry(%__MODULE__{entries: entries}, id), do: Map.get(entries, id)

  @spec delete_turn(t(), String.t()) :: t()
  def delete_turn(%__MODULE__{} = memory, turn_id) do
    deleted =
      for {id, %Entry{turn_id: ^turn_id}} <- memory.entries, into: MapSet.new(), do: id

    if MapSet.size(deleted) == 0 do
      raise Normandy.NonExistentTurn, value: turn_id
    end

    entries =
      memory.entries
      |> Enum.reject(fn {id, _entry} -> MapSet.member?(deleted, id) end)
      |> Map.new(fn {id, entry} ->
        {id, %{entry | parent_id: surviving_ancestor(entry.parent_id, memory.entries, deleted)}}
      end)

    head = surviving_ancestor(memory.head, memory.entries, deleted)

    %{memory | entries: entries, head: head}
  end

  @spec dump(t()) :: String.t()
  def dump(%__MODULE__{} = memory) do
    adapter = Application.get_env(:normandy, :adapter, Poison)

    encoded_entries =
      for {_id, %Entry{} = e} <- memory.entries do
        %{
          id: e.id,
          parent_id: e.parent_id,
          turn_id: e.turn_id,
          role: e.role,
          content: encode_content(e.content)
        }
      end

    adapter.encode!(%{
      version: 1,
      max_messages: memory.max_messages,
      current_turn_id: memory.current_turn_id,
      head: memory.head,
      entries: encoded_entries
    })
  end

  @spec load(String.t()) :: t()
  def load(dump) do
    adapter = Application.get_env(:normandy, :adapter, Poison)
    loaded = adapter.decode!(dump, keys: :atoms)

    entries =
      loaded.entries
      |> Enum.map(fn e ->
        {e.id,
         %Entry{
           id: e.id,
           parent_id: e.parent_id,
           turn_id: e.turn_id,
           role: e.role,
           content: decode_content(e.content)
         }}
      end)
      |> Map.new()

    %__MODULE__{
      entries: entries,
      head: Map.get(loaded, :head),
      current_turn_id: Map.get(loaded, :current_turn_id),
      max_messages: Map.get(loaded, :max_messages)
    }
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp entry_to_message(%Entry{turn_id: turn_id, role: role, content: content}) do
    %Message{turn_id: turn_id, role: role, content: content}
  end

  # Walk head -> root, newest entry first.
  defp chain_newest_first(%__MODULE__{head: head, entries: entries}) do
    Stream.unfold(head, fn
      nil ->
        nil

      id ->
        case Map.get(entries, id) do
          nil -> nil
          %Entry{parent_id: parent_id} = entry -> {entry, parent_id}
        end
    end)
    |> Enum.to_list()
  end

  defp enforce_max_messages(%__MODULE__{max_messages: nil} = memory), do: memory

  defp enforce_max_messages(%__MODULE__{max_messages: 0} = memory) do
    %{memory | entries: %{}, head: nil}
  end

  defp enforce_max_messages(%__MODULE__{max_messages: max} = memory) do
    chain = chain_newest_first(memory)

    if length(chain) <= max do
      memory
    else
      kept = Enum.take(chain, max)
      dropped = Enum.drop(chain, max)
      oldest_kept = List.last(kept)

      entries =
        dropped
        |> Enum.reduce(memory.entries, fn %Entry{id: id}, acc -> Map.delete(acc, id) end)
        |> Map.update!(oldest_kept.id, fn entry -> %{entry | parent_id: nil} end)

      %{memory | entries: entries}
    end
  end

  # Nearest non-deleted id walking up parent links; nil if none survives.
  defp surviving_ancestor(nil, _entries, _deleted), do: nil

  defp surviving_ancestor(id, entries, deleted) do
    if MapSet.member?(deleted, id) do
      case Map.get(entries, id) do
        %Entry{parent_id: parent_id} -> surviving_ancestor(parent_id, entries, deleted)
        nil -> nil
      end
    else
      id
    end
  end

  defp encode_content(content) when is_struct(content) do
    %{type: to_string(content.__struct__), data: content}
  end

  defp encode_content(content), do: %{type: "raw", data: content}

  defp decode_content(%{type: "raw", data: data}), do: data

  defp decode_content(%{type: type, data: data}) do
    mod = String.to_existing_atom(type)
    struct(mod, data)
  end
end
