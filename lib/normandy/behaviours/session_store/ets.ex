defmodule Normandy.Behaviours.SessionStore.ETS do
  @moduledoc """
  ETS-backed `SessionStore` — fast, in-node. A GenServer owns a private ETS table
  and serializes every mutation through its mailbox, so concurrent appends/forks to
  the same `session_id` cannot clobber each other (the read-modify-write of a
  session's `%AgentMemory{}` is exclusive). The handle is the owner pid.

  Each session's `AgentMemory` is stored under `{:session, session_id}` and its
  opaque turn state under `{:turn_state, session_id}`. The table is private to the
  owner; start one store per logical session space. Not yet consumed by the turn
  loop (Phase 4 wires it as the writer).
  """

  @behaviour Normandy.Behaviours.SessionStore

  use GenServer

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry

  # ── client ───────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "Start a fresh ETS-backed store; returns its handle (the owner pid)."
  @spec new(keyword()) :: pid()
  def new(opts \\ []) do
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
  def fork(pid, session_id, from_entry_id) do
    GenServer.call(pid, {:fork, session_id, from_entry_id})
  end

  @impl Normandy.Behaviours.SessionStore
  def save_turn_state(pid, session_id, term) do
    GenServer.call(pid, {:save_turn_state, session_id, term})
  end

  @impl Normandy.Behaviours.SessionStore
  def load_turn_state(pid, session_id) do
    GenServer.call(pid, {:load_turn_state, session_id})
  end

  # ── server ───────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, :normandy_session_store)
    {:ok, :ets.new(name, [:set, :private])}
  end

  @impl GenServer
  def handle_call({:append_entry, session_id, entry}, _from, table) do
    memory = lookup_memory(table, session_id)
    id = entry.id || UUID.uuid4()
    entry = %{entry | id: id, parent_id: entry.parent_id || memory.head}
    memory = %{memory | entries: Map.put(memory.entries, id, entry), head: id}
    :ets.insert(table, {{:session, session_id}, memory})
    {:reply, {:ok, id}, table}
  end

  def handle_call({:history, session_id}, _from, table) do
    {:reply, {:ok, table |> lookup_memory(session_id) |> AgentMemory.entry_chain()}, table}
  end

  def handle_call({:fork, session_id, from_entry_id}, _from, table) do
    reply =
      case :ets.lookup(table, {:session, session_id}) do
        [] ->
          {:error, :no_such_session}

        [{_, %AgentMemory{} = memory}] ->
          case AgentMemory.fork(memory, from_entry_id) do
            {:error, reason} ->
              {:error, reason}

            {:ok, forked} ->
              new_id = UUID.uuid4()
              :ets.insert(table, {{:session, new_id}, forked})
              {:ok, new_id}
          end
      end

    {:reply, reply, table}
  end

  def handle_call({:save_turn_state, session_id, term}, _from, table) do
    :ets.insert(table, {{:turn_state, session_id}, term})
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

  defp lookup_memory(table, session_id) do
    case :ets.lookup(table, {:session, session_id}) do
      [{_, %AgentMemory{} = memory}] -> memory
      [] -> AgentMemory.new_memory()
    end
  end
end
