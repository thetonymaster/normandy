defmodule Normandy.Behaviours.SessionStore.ETS do
  @moduledoc """
  ETS-backed `SessionStore` — fast, in-node. A GenServer owns a private ETS table
  and serializes every mutation through its mailbox, so concurrent appends and forks
  to the same `session_id` cannot clobber each other. The handle is the owner pid.

  One row per entry: `{{:entry, session_id, id}, %Entry{}}`, plus the session's head
  `{{:head, session_id}, id}`, its opaque turn state `{{:turn_state, session_id}, term}`,
  its config template `{{:config_template, session_id}, template}` and, while its turn
  is in flight, `{{:inflight, session_id}}`. An append
  writes two rows whatever the history's length; `history/2` walks `parent_id` from
  the head (O(n), once per server start). `fork/3` copies the chain from the fork
  point back to the root into the new session. The table is private to the owner;
  start one store per logical session space.
  """

  @behaviour Normandy.Behaviours.SessionStore

  use GenServer

  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Options

  @opts_schema NimbleOptions.new!(
                 name: [
                   type: :atom,
                   default: :normandy_session_store,
                   doc: "The ETS table's name (a label: the table is not a named table)."
                 ]
               )

  # ── client ───────────────────────────────────────────────────────────────────

  @doc """
  Starts an ETS-backed store.

  ## Options

  #{Options.docs(@opts_schema)}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Options.validate!(opts, @opts_schema, {__MODULE__, :start_link, 1})
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Starts a fresh ETS-backed store; returns its handle (the owner pid).

  ## Options

  #{Options.docs(@opts_schema)}
  """
  @spec new(keyword()) :: pid()
  def new(opts \\ []) do
    opts = Options.validate!(opts, @opts_schema, {__MODULE__, :new, 1})
    {:ok, pid} = start_link(opts)
    pid
  end

  @impl Normandy.Behaviours.SessionStore
  def append_entry(pid, session_id, %Entry{} = entry) do
    GenServer.call(pid, {:append_entry, session_id, entry})
  end

  @impl Normandy.Behaviours.SessionStore
  def history(pid, session_id) do
    GenServer.call(pid, {:history, session_id})
  end

  @impl Normandy.Behaviours.SessionStore
  def history_since_compaction(pid, session_id) do
    GenServer.call(pid, {:history_since_compaction, session_id})
  end

  @impl Normandy.Behaviours.SessionStore
  def fork(pid, session_id, from_entry_id) do
    GenServer.call(pid, {:fork, session_id, from_entry_id})
  end

  @impl Normandy.Behaviours.SessionStore
  def save_turn_state(pid, session_id, term, inflight?) when is_boolean(inflight?) do
    GenServer.call(pid, {:save_turn_state, session_id, term, inflight?})
  end

  @impl Normandy.Behaviours.SessionStore
  def load_turn_state(pid, session_id) do
    GenServer.call(pid, {:load_turn_state, session_id})
  end

  @impl Normandy.Behaviours.SessionStore
  def save_config_template(pid, session_id, tmpl),
    do: GenServer.call(pid, {:save_config_template, session_id, tmpl})

  @impl Normandy.Behaviours.SessionStore
  def load_config_template(pid, session_id),
    do: GenServer.call(pid, {:load_config_template, session_id})

  @impl Normandy.Behaviours.SessionStore
  def list_resumable(pid), do: GenServer.call(pid, :list_resumable)

  @impl Normandy.Behaviours.SessionStore
  def delete_session(pid, session_id), do: GenServer.call(pid, {:delete_session, session_id})

  # ── server ───────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    # Ordered, so a session's entry rows ({:entry, sid, _}) are one key range.
    {:ok, :ets.new(name, [:ordered_set, :private])}
  end

  @impl GenServer
  def handle_call({:append_entry, session_id, entry}, _from, table) do
    id = entry.id || UUID.uuid4()
    entry = %{entry | id: id, parent_id: entry.parent_id || head(table, session_id)}
    :ets.insert(table, [{{:entry, session_id, id}, entry}, {{:head, session_id}, id}])
    {:reply, {:ok, id}, table}
  end

  def handle_call({:history, session_id}, _from, table) do
    {:reply, {:ok, chain(table, session_id, head(table, session_id))}, table}
  end

  def handle_call({:history_since_compaction, session_id}, _from, table) do
    head = head(table, session_id)
    {:reply, {:ok, chain(table, session_id, head, %{}, [], :since_compaction)}, table}
  end

  def handle_call({:fork, session_id, from_entry_id}, _from, table) do
    reply =
      cond do
        head(table, session_id) == nil ->
          {:error, :no_such_session}

        not :ets.member(table, {:entry, session_id, from_entry_id}) ->
          {:error, :no_such_entry}

        true ->
          new_id = UUID.uuid4()
          copied = chain(table, session_id, from_entry_id)
          rows = for %Entry{id: id} = e <- copied, do: {{:entry, new_id, id}, e}
          :ets.insert(table, [{{:head, new_id}, from_entry_id} | rows])
          {:ok, new_id}
      end

    {:reply, reply, table}
  end

  def handle_call({:save_turn_state, session_id, term, inflight?}, _from, table) do
    :ets.insert(table, {{:turn_state, session_id}, term})

    if inflight?,
      do: :ets.insert(table, {{:inflight, session_id}}),
      else: :ets.delete(table, {:inflight, session_id})

    {:reply, :ok, table}
  end

  def handle_call({:load_turn_state, session_id}, _from, table) do
    reply =
      case :ets.lookup(table, {:turn_state, session_id}) do
        [{_, term}] -> {:ok, term}
        [] -> :error
      end

    {:reply, reply, table}
  end

  def handle_call({:save_config_template, session_id, tmpl}, _from, table) do
    :ets.insert(table, {{:config_template, session_id}, tmpl})
    {:reply, :ok, table}
  end

  def handle_call({:load_config_template, session_id}, _from, table) do
    reply =
      case :ets.lookup(table, {:config_template, session_id}) do
        [{_, tmpl}] -> {:ok, tmpl}
        [] -> :error
      end

    {:reply, reply, table}
  end

  def handle_call(:list_resumable, _from, table) do
    {:reply, {:ok, List.flatten(:ets.match(table, {{:inflight, :"$1"}}))}, table}
  end

  def handle_call({:delete_session, session_id}, _from, table) do
    # A fork copies its entries, so every {:entry, session_id, _} row is this session's.
    :ets.match_delete(table, {{:entry, session_id, :_}, :_})

    for key <- [:head, :turn_state, :config_template, :inflight],
        do: :ets.delete(table, {key, session_id})

    {:reply, :ok, table}
  end

  defp head(table, session_id) do
    case :ets.lookup(table, {:head, session_id}) do
      [{_, id}] -> id
      [] -> nil
    end
  end

  # The chain from `id` back to the root, chronological. Stops at a missing parent or
  # an entry already seen, as AgentMemory.entry_chain/1 does (an append may name any
  # parent_id).
  # With :since_compaction it also stops after the first "compaction" entry it meets.
  defp chain(table, session_id, id), do: chain(table, session_id, id, %{}, [], :all)

  defp chain(_table, _sid, nil, _seen, acc, _until), do: acc

  defp chain(_table, _sid, _id, _seen, [%Entry{role: "compaction"} | _] = acc, :since_compaction),
    do: acc

  defp chain(table, session_id, id, seen, acc, until) do
    with false <- Map.has_key?(seen, id),
         [{_, %Entry{parent_id: parent} = entry}] <- :ets.lookup(table, {:entry, session_id, id}) do
      chain(table, session_id, parent, Map.put(seen, id, true), [entry | acc], until)
    else
      _stop -> acc
    end
  end
end
