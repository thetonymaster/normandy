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
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Components.Message

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

  @doc """
  Appends a message to the active branch.

  `turn_id:` stores the message under that turn instead of `current_turn_id`;
  compaction uses it to keep each kept message's turn.
  """
  @spec add_message(t(), String.t(), term(), keyword()) :: t()
  def add_message(%__MODULE__{} = memory, role, content, opts \\ []) do
    opts = Keyword.validate!(opts, [:turn_id])
    memory = if memory.current_turn_id == nil, do: initialize_turn(memory), else: memory

    id = UUID.uuid4()

    entry = %Entry{
      id: id,
      parent_id: memory.head,
      turn_id: Keyword.get(opts, :turn_id, memory.current_turn_id),
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

  @doc """
  Rebuild a memory from a chronological list of `Entry.t()` (e.g. the output of
  `SessionStore.history/2`). The `head` becomes the last entry's id and the
  `current_turn_id` the last entry's `turn_id`, so the active branch reconstructs.
  """
  @spec from_entries([Entry.t()]) :: t()
  def from_entries([]), do: new_memory()

  def from_entries(entries) when is_list(entries) do
    last = List.last(entries)

    %__MODULE__{
      entries: Map.new(entries, fn %Entry{id: id} = e -> {id, e} end),
      head: last.id,
      current_turn_id: last.turn_id,
      max_messages: nil
    }
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
    # Decode with string keys only. A dump can carry untrusted/raw content, and a
    # blanket `keys: :atoms` would intern every nested content key — an atom-table
    # exhaustion vector. We read the fixed envelope by string key and atomize
    # nothing outside known struct field names (see decode_content/1).
    loaded = adapter.decode!(dump)

    case loaded["version"] do
      1 ->
        :ok

      version ->
        raise ArgumentError,
              "AgentMemory.load/1: unsupported dump version #{inspect(version)} (expected 1)"
    end

    entries =
      for e <- loaded["entries"], into: %{} do
        {e["id"],
         %Entry{
           id: e["id"],
           parent_id: e["parent_id"],
           turn_id: e["turn_id"],
           role: e["role"],
           content: decode_content(e["content"])
         }}
      end

    %__MODULE__{
      entries: entries,
      head: loaded["head"],
      current_turn_id: loaded["current_turn_id"],
      max_messages: loaded["max_messages"]
    }
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp entry_to_message(%Entry{turn_id: turn_id, role: role, content: content}) do
    %Message{turn_id: turn_id, role: role, content: content}
  end

  # Walk head -> root, newest entry first. Tracks visited ids so a corrupt
  # parent_id cycle (e.g. from a malformed dump or a duplicate-id append)
  # terminates gracefully instead of looping forever.
  defp chain_newest_first(%__MODULE__{head: head, entries: entries}) do
    Stream.unfold({head, MapSet.new()}, fn
      {nil, _visited} ->
        nil

      {id, visited} ->
        if MapSet.member?(visited, id) do
          nil
        else
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case Map.get(entries, id) do
            nil -> nil
            %Entry{parent_id: parent_id} = entry -> {entry, {parent_id, MapSet.put(visited, id)}}
          end
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
    keep = keep_count(Enum.map(chain, & &1.role), max)

    if length(chain) <= keep do
      memory
    else
      kept = Enum.take(chain, keep)
      dropped = Enum.drop(chain, keep)
      oldest_kept = List.last(kept)

      entries =
        dropped
        |> Enum.reduce(memory.entries, fn %Entry{id: id}, acc -> Map.delete(acc, id) end)
        |> Map.update!(oldest_kept.id, fn entry -> %{entry | parent_id: nil} end)

      %{memory | entries: entries}
    end
  end

  # How many of the newest entries to keep (roles are newest first). The API
  # rejects a conversation that starts with an assistant turn or a tool result
  # whose tool_use was cut, so the window starts at a user message: the oldest
  # one within `max`, or, when none fits, the newest one (the window then holds
  # more than `max` until the turn ends). A memory with no user message at all
  # is cut at `max`.
  @doc false
  def keep_count(roles_newest_first, max) do
    window = Enum.take(roles_newest_first, max)

    oldest_user_in_window =
      window |> Enum.with_index() |> Enum.filter(&(elem(&1, 0) == "user")) |> List.last()

    case oldest_user_in_window do
      {"user", index} ->
        index + 1

      nil ->
        case Enum.find_index(roles_newest_first, &(&1 == "user")) do
          nil -> max
          index -> index + 1
        end
    end
  end

  # Nearest non-deleted id walking up parent links; nil if none survives. Tracks
  # visited ids so a corrupt parent cycle (same vector `chain_newest_first/1`
  # guards against) terminates instead of looping forever.
  defp surviving_ancestor(id, entries, deleted),
    do: surviving_ancestor(id, entries, deleted, %{})

  defp surviving_ancestor(nil, _entries, _deleted, _visited), do: nil

  defp surviving_ancestor(id, entries, deleted, visited) do
    cond do
      Map.has_key?(visited, id) ->
        nil

      MapSet.member?(deleted, id) ->
        case Map.get(entries, id) do
          %Entry{parent_id: parent_id} ->
            surviving_ancestor(parent_id, entries, deleted, Map.put(visited, id, true))

          nil ->
            nil
        end

      true ->
        id
    end
  end

  # Nested Normandy schema structs (e.g. the %ToolCall{}s inside a ToolCallResponse)
  # are tagged with their module so load/1 can rebuild them; JSON alone would bring
  # them back as string-keyed maps. `__meta__` is dropped: the struct default
  # restores it on load.
  @struct_tag "$normandy_struct"

  defp encode_content(content) when is_struct(content) do
    data = if schema_struct?(content), do: encode_fields(content), else: content
    %{type: to_string(content.__struct__), data: data}
  end

  defp encode_content(content), do: %{type: "raw", data: encode_value(content)}

  defp encode_value(value) when is_struct(value) do
    if schema_struct?(value),
      do: %{@struct_tag => to_string(value.__struct__), "data" => encode_fields(value)},
      else: value
  end

  defp encode_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, encode_value(v)} end)

  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)
  defp encode_value(value), do: value

  defp encode_fields(struct) do
    struct |> Map.from_struct() |> Map.delete(:__meta__) |> encode_value()
  end

  defp schema_struct?(%mod{}), do: function_exported?(mod, :__schema__, 1)

  # Raw (non-struct) content round-trips verbatim — its keys stay strings, so an
  # untrusted dump cannot grow the atom table.
  defp decode_content(%{"type" => "raw", "data" => data}), do: decode_value(data)

  # Struct content rebuilds onto the named module. Only the struct's own field
  # names are atomized, via `to_existing_atom` (which never mints a new atom), so a
  # hostile dump still cannot exhaust the atom table.
  defp decode_content(%{"type" => type, "data" => data}), do: decode_struct(type, data)

  defp decode_value(%{@struct_tag => type, "data" => data}), do: decode_struct(type, data)

  defp decode_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, decode_value(v)} end)

  defp decode_value(value) when is_list(value), do: Enum.map(value, &decode_value/1)
  defp decode_value(value), do: value

  # Only a module defined with Normandy.Schema is rebuilt: a dump is data, and
  # must not choose arbitrary loaded structs (with fields it picks) to build.
  defp decode_struct(type, data) do
    mod = schema_module!(type)

    mod
    |> struct(data |> Map.delete("__meta__") |> decode_value() |> atomize_struct_fields())
    |> restore_atom_fields()
  end

  defp schema_module!(type) do
    mod =
      try do
        String.to_existing_atom(type)
      rescue
        ArgumentError -> nil
      end

    if mod && Code.ensure_loaded?(mod) && function_exported?(mod, :__schema__, 1) do
      mod
    else
      raise ArgumentError,
            "AgentMemory.load/1: dump names a struct that is not a Normandy schema: #{inspect(type)}"
    end
  end

  # JSON turns atom field values into strings. Content blocks keep their source
  # as an atom, so map the known values back.
  @atom_field_values %{
    Normandy.Components.ContentBlock.Image => {:source, ~w(base64 url)a},
    Normandy.Components.ContentBlock.Document => {:source, ~w(file_id)a}
  }

  defp restore_atom_fields(%mod{} = struct) do
    case Map.fetch(@atom_field_values, mod) do
      {:ok, {field, allowed}} ->
        value = Map.fetch!(struct, field)
        atom = Enum.find(allowed, &(Atom.to_string(&1) == value))
        if atom, do: Map.put(struct, field, atom), else: struct

      :error ->
        struct
    end
  end

  defp atomize_struct_fields(data) do
    for {key, value} <- data, into: %{}, do: {String.to_existing_atom(key), value}
  end
end
