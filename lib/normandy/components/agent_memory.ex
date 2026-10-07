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

  Each entry's model-facing encoding is computed once, when its content is set (an
  append, a thinking drop, `from_entries/1`, `load/1`), and kept on the entry
  (`Normandy.Components.AgentMemory.Entry`'s `wire` and `tokens`). Building a request
  or estimating the conversation reads it, so a content that cannot be encoded raises
  at the append rather than at the next LLM call.
  """

  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Components.Message
  alias Normandy.Context.WindowManager
  alias Normandy.Options

  defstruct entries: %{}, head: nil, current_turn_id: nil, max_messages: nil

  @type t :: %__MODULE__{
          entries: %{String.t() => Entry.t()},
          head: String.t() | nil,
          current_turn_id: String.t() | nil,
          max_messages: pos_integer() | nil
        }

  @add_message_opts_schema NimbleOptions.new!(
                             turn_id: [
                               type: {:or, [:string, nil]},
                               doc:
                                 "Store the message under this turn instead of the current one."
                             ],
                             id: [
                               type: {:or, [:string, nil]},
                               doc:
                                 "The entry's id (default: a new UUID). It must not already be " <>
                                   "in the memory."
                             ]
                           )

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
  compaction uses it to keep each kept message's turn. `id:` gives the entry that id
  instead of a new one (compaction keeps a kept message's id, which compactors report
  dropped entries by); it must not already be in `memory` (raises `ArgumentError`).

  ## Options

  #{Options.docs(@add_message_opts_schema)}
  """
  @spec add_message(t(), String.t(), term(), keyword()) :: t()
  def add_message(%__MODULE__{} = memory, role, content, opts \\ []) do
    opts = Options.validate!(opts, @add_message_opts_schema, {__MODULE__, :add_message, 4})
    memory = if memory.current_turn_id == nil, do: initialize_turn(memory), else: memory

    id = Keyword.get(opts, :id) || UUID.uuid4()

    if Map.has_key?(memory.entries, id) do
      raise ArgumentError,
            "Normandy.Components.AgentMemory.add_message/4: entry id #{inspect(id)} is already in the memory; " <>
              "an :id must be new (it would overwrite the existing entry and corrupt the branch)"
    end

    entry =
      put_content(
        %Entry{
          id: id,
          parent_id: memory.head,
          turn_id: Keyword.get(opts, :turn_id, memory.current_turn_id),
          role: role
        },
        content
      )

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
    |> entry_chain()
    |> Enum.map(fn %Entry{role: role} = entry -> %{role: role, content: entry_wire(entry)} end)
  end

  @doc false
  # What the model is sent for `entry`: its cached `wire`, or (an entry built by hand,
  # or decoded from a term written before the field existed) the encoding computed now.
  @spec entry_wire(Entry.t()) :: String.t() | list()
  def entry_wire(entry), do: Map.get(entry, :wire) || model_content(entry.content)

  @doc false
  # The entry's token estimate (Context.WindowManager's, plus 10 for the message),
  # cached like entry_wire/1.
  @spec entry_tokens(Entry.t()) :: non_neg_integer()
  def entry_tokens(entry),
    do: Map.get(entry, :tokens) || estimate_tokens(entry_wire(entry))

  @doc false
  # The memory with every entry's cache cleared: what ConfigTemplate persists, so a
  # template never carries an encoding another Normandy version would replay.
  @spec drop_cache(t()) :: t()
  def drop_cache(%__MODULE__{entries: entries} = memory) do
    %{memory | entries: Map.new(entries, fn {id, entry} -> {id, bare_entry(entry)} end)}
  end

  @doc false
  # The memory with every entry's cache computed (ConfigTemplate.rebuild/3).
  @spec fill_cache(t()) :: t()
  def fill_cache(%__MODULE__{entries: entries} = memory) do
    %{memory | entries: Map.new(entries, fn {id, entry} -> {id, fill_entry(entry)} end)}
  end

  @doc """
  The messages of a request, from `history/1`'s output.

  Each run of consecutive `"tool"` messages whose content is a block list becomes one
  `"tool"` message holding their blocks in order, so a batch of tool results reaches the
  model as one user message, as the Messages API expects of parallel tool use. Memory,
  the session store and the turn keep one entry per result; only the request merges
  them. A `"tool"` message whose content is not a list stays a message of its own.

  A non-empty text `"user"` message right after such a run (the iteration-cap notice, an
  `after_compact` injection) becomes its last block, as the API expects text sent with
  tool results.
  """
  @spec request_messages([%{role: String.t(), content: term()}]) :: [Message.t()]
  def request_messages(history) when is_list(history) do
    history
    |> Enum.reduce([], &add_request_message/2)
    |> Enum.reverse()
    |> fold_user_text()
  end

  @doc false
  # The messages of a request built from `memory` in one walk of the active branch:
  # each entry's cached encoding, with the thinking drop_stale_thinking/2 would remove
  # under `prefix_key` removed from that encoding (drop_thinking/1 on the encoded blocks
  # gives what encoding the dropped content gives), then merged as request_messages/1
  # merges. Equal to
  # `memory |> drop_stale_thinking(prefix_key) |> history() |> request_messages()`,
  # without encoding anything again.
  @spec request_messages_for(t(), integer()) :: [Message.t()]
  def request_messages_for(%__MODULE__{} = memory, prefix_key) do
    {history, _state} =
      memory
      |> entry_chain()
      |> Enum.map_reduce(:leading, fn %Entry{role: role, content: content} = entry, state ->
        case thinking_verdict(content, prefix_key, state) do
          {:keep, state} -> {%{role: role, content: entry_wire(entry)}, state}
          {:drop, state} -> {%{role: role, content: drop_thinking(entry_wire(entry))}, state}
        end
      end)

    request_messages(history)
  end

  defp fold_user_text([
         %Message{role: "tool", content: blocks} = tool,
         %Message{role: "user", content: text} | rest
       ])
       when is_list(blocks) and is_binary(text) and text != "" do
    fold_user_text([%{tool | content: blocks ++ [%{type: "text", text: text}]} | rest])
  end

  defp fold_user_text([message | rest]), do: [message | fold_user_text(rest)]
  defp fold_user_text([]), do: []

  defp add_request_message(
         %{role: "tool", content: blocks},
         [%Message{role: "tool", content: previous} = last | rest]
       )
       when is_list(blocks) and is_list(previous),
       do: [%{last | content: previous ++ blocks} | rest]

  defp add_request_message(%{role: role, content: content}, acc),
    do: [%Message{role: role, content: content} | acc]

  # The default chat input goes to the model as the user's own words. Sent as
  # {"chat_message": ...} JSON, Haiku 4.5 read earlier turns as data rather than
  # conversation and denied remembering them.
  defp model_content(%Normandy.Agents.BaseAgentInputSchema{chat_message: text})
       when is_binary(text),
       do: text

  # The default chat output, likewise: an earlier answer replayed as
  # {"chat_message": ...} JSON taught the model to answer in JSON (AX-21).
  defp model_content(%Normandy.Agents.BaseAgentOutputSchema{chat_message: text})
       when is_binary(text),
       do: text

  defp model_content(content), do: BaseIOSchema.to_json(content)

  # The only place an entry's content is set: content, wire and tokens change together.
  defp put_content(%Entry{} = entry, content) do
    wire = model_content(content)
    %Entry{entry | content: content, wire: wire, tokens: estimate_tokens(wire)}
  end

  defp estimate_tokens(wire), do: WindowManager.estimate_message_content_tokens(wire) + 10

  # An entry with its five stored fields and no cache. struct/2 reads only those keys,
  # so it also takes an entry decoded from a term written before `wire` existed.
  defp bare_entry(entry),
    do: struct(Entry, Map.take(entry, [:id, :parent_id, :turn_id, :role, :content]))

  defp fill_entry(entry) do
    bare = bare_entry(entry)
    put_content(bare, bare.content)
  end

  # Thinking is dropped by re-setting the content, so the cache follows; an entry with
  # none is returned as it is (nothing to re-encode).
  defp strip_thinking(%Entry{content: content} = entry) do
    if has_thinking?(content), do: put_content(entry, drop_thinking(content)), else: entry
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

  @doc "Looks up the entry with id `id`: `{:ok, entry}` or `:error`."
  @spec fetch_entry(t(), String.t()) :: {:ok, Entry.t()} | :error
  def fetch_entry(%__MODULE__{entries: entries}, id), do: Map.fetch(entries, id)

  @doc """
  Like `fetch_entry/2`, but returns the entry or raises `KeyError` (its message names the
  id, never the memory).
  """
  @spec fetch_entry!(t(), String.t()) :: Entry.t()
  def fetch_entry!(%__MODULE__{entries: entries}, id) do
    case Map.fetch(entries, id) do
      {:ok, entry} -> entry
      :error -> raise KeyError, key: id, message: "no entry #{inspect(id)} in this AgentMemory"
    end
  end

  @doc """
  Removes every entry of turn `turn_id`, re-linking the survivors around it. Raises
  `Normandy.TurnNotFoundError` when the memory has no entry of that turn.
  """
  @spec delete_turn(t(), String.t()) :: t()
  def delete_turn(%__MODULE__{} = memory, turn_id) do
    deleted =
      for {id, %Entry{turn_id: ^turn_id}} <- memory.entries, into: MapSet.new(), do: id

    if MapSet.size(deleted) == 0 do
      raise Normandy.TurnNotFoundError, turn_id: turn_id
    end

    entries =
      memory.entries
      |> Enum.reject(fn {id, _entry} -> MapSet.member?(deleted, id) end)
      |> Map.new(fn {id, entry} ->
        {id, %{entry | parent_id: surviving_ancestor(entry.parent_id, memory.entries, deleted)}}
      end)

    head = surviving_ancestor(memory.head, memory.entries, deleted)

    # Messages after the deleted turn were produced with it in their history.
    entries =
      Map.new(entries, fn {id, entry} ->
        if after_deleted?(entry.parent_id, memory.entries, deleted),
          do: {id, strip_thinking(entry)},
          else: {id, entry}
      end)

    %{memory | entries: entries, head: head}
  end

  defp after_deleted?(nil, _entries, _deleted), do: false

  defp after_deleted?(id, entries, deleted) do
    MapSet.member?(deleted, id) or after_deleted?(entries[id].parent_id, entries, deleted)
  end

  @doc """
  Drops thinking that no longer applies under the current system prompt and tools,
  given as `prefix_key` (see `Normandy.Agents.ToolCallResponse.prefix_key/3`).

  Walking the active chain oldest first, a `ToolCallResponse` whose `:prefix_key`
  differs loses its thinking. Earlier thinking is not part of a block's prefix, so
  dropping a leading run leaves later blocks valid; once a block has been kept, a
  dropped one breaks the chain and every later message loses its thinking too.
  Responses without a key (stored before it existed) are left as they are.
  """
  @spec drop_stale_thinking(t(), integer()) :: t()
  def drop_stale_thinking(%__MODULE__{} = memory, prefix_key) do
    {entries, _state} =
      memory
      |> chain_newest_first()
      |> Enum.reverse()
      |> Enum.reduce({memory.entries, :leading}, fn %Entry{id: id} = entry, {entries, state} ->
        case thinking_verdict(entry.content, prefix_key, state) do
          {:keep, state} ->
            {entries, state}

          {:drop, state} ->
            {Map.put(entries, id, put_content(entry, drop_thinking(entry.content))), state}
        end
      end)

    %{memory | entries: entries}
  end

  # state: :leading (no thinking kept yet), :kept (some kept), :broken (a block
  # after a kept one was dropped).
  defp thinking_verdict(content, prefix_key, state) do
    cond do
      not has_thinking?(content) -> {:keep, state}
      state == :broken -> {:drop, :broken}
      stale?(content, prefix_key) -> {:drop, if(state == :kept, do: :broken, else: :leading)}
      true -> {:keep, :kept}
    end
  end

  defp has_thinking?(%Normandy.Agents.ToolCallResponse{thinking: thinking}), do: thinking != []
  defp has_thinking?(blocks) when is_list(blocks), do: Enum.any?(blocks, &thinking_block?/1)
  defp has_thinking?(_content), do: false

  defp stale?(%Normandy.Agents.ToolCallResponse{prefix_key: key}, current),
    do: key != nil and key != current

  defp stale?(_content, _current), do: false

  @doc """
  Removes `thinking` and `redacted_thinking` blocks from a message's content:
  a `ToolCallResponse`'s `:thinking`, or the blocks of a content list. Other
  content is returned unchanged.

  A thinking block is valid only after the exact history that produced it, so
  memory edits that remove or replace earlier messages (a `max_messages` trim,
  `delete_turn/2`, summarizing or truncating with `Normandy.Context`) drop the
  thinking of the messages they kept. Text and tool calls stay.
  """
  @spec drop_thinking(term()) :: term()
  def drop_thinking(%Normandy.Agents.ToolCallResponse{} = response),
    do: %{response | thinking: []}

  def drop_thinking(blocks) when is_list(blocks), do: Enum.reject(blocks, &thinking_block?/1)
  def drop_thinking(content), do: content

  defp thinking_block?(block) when is_map(block) and not is_struct(block),
    do:
      (Map.get(block, :type) || Map.get(block, "type")) in [
        :thinking,
        :redacted_thinking,
        "thinking",
        "redacted_thinking"
      ]

  defp thinking_block?(_block), do: false

  @doc """
  Rebuild a memory from a chronological list of `Entry.t()` (e.g. the output of
  `SessionStore.history/2`). The `head` becomes the last entry's id and the
  `current_turn_id` the last entry's `turn_id`, so the active branch reconstructs.
  Each entry's encoding is computed here, once.
  """
  @spec from_entries([Entry.t()]) :: t()
  def from_entries([]), do: new_memory()

  def from_entries(entries) when is_list(entries) do
    last = List.last(entries)

    %__MODULE__{
      entries: Map.new(entries, fn %Entry{id: id} = e -> {id, fill_entry(e)} end),
      head: last.id,
      current_turn_id: last.turn_id,
      max_messages: nil
    }
  end

  @spec dump(t()) :: String.t()
  def dump(%__MODULE__{} = memory) do
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

    Normandy.JSON.encode!(%{
      version: 1,
      max_messages: memory.max_messages,
      current_turn_id: memory.current_turn_id,
      head: memory.head,
      entries: encoded_entries
    })
  end

  @spec load(String.t()) :: t()
  def load(dump) do
    # Decode with string keys only. A dump can carry untrusted/raw content, and a
    # blanket `keys: :atoms` would intern every nested content key — an atom-table
    # exhaustion vector. We read the fixed envelope by string key and atomize
    # nothing outside known struct field names (see decode_content/1).
    loaded = Normandy.JSON.decode!(dump)

    case loaded["version"] do
      1 ->
        :ok

      version ->
        raise ArgumentError,
              "AgentMemory.load/1: unsupported dump version #{inspect(version)} (expected 1)"
    end

    entries = for e <- loaded["entries"], into: %{}, do: {e["id"], load_entry(e)}

    %__MODULE__{
      entries: entries,
      head: loaded["head"],
      current_turn_id: loaded["current_turn_id"],
      max_messages: loaded["max_messages"]
    }
  end

  # ── internals ───────────────────────────────────────────────────────────────

  # A dump is data: content the model cannot be sent (a 1.x tool call stored as a plain
  # map) is refused here, naming the entry, rather than at the next request.
  defp load_entry(e) do
    entry = %Entry{id: e["id"], parent_id: e["parent_id"], turn_id: e["turn_id"], role: e["role"]}
    content = decode_content(e["content"])

    try do
      put_content(entry, content)
    rescue
      error ->
        reraise ArgumentError,
                [
                  message:
                    "AgentMemory.load/1: entry #{inspect(entry.id)} has content that cannot be " <>
                      "encoded for the model (#{inspect(error.__struct__)})"
                ],
                __STACKTRACE__
    end
  end

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

      # Every kept message was produced after the dropped ones.
      entries =
        dropped
        |> Enum.reduce(memory.entries, fn %Entry{id: id}, acc -> Map.delete(acc, id) end)
        |> Map.update!(oldest_kept.id, fn entry -> %{entry | parent_id: nil} end)
        |> Map.new(fn {id, entry} -> {id, strip_thinking(entry)} end)

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
