defmodule Normandy.Behaviours.SessionStore.ETS do
  @moduledoc """
  ETS-backed `SessionStore` — fast, in-node. The handle is a table id; each
  session's `AgentMemory` is stored under `{:session, session_id}` and its opaque
  turn state under `{:turn_state, session_id}`. Anonymous (non-`:named_table`) so
  multiple stores coexist; not consumed by the turn loop in Phase 3.

  Reads-then-writes are not atomic across the table — adequate for the Phase 3
  contract and single-writer use. Concurrency hardening (a serializing owner) is a
  Phase 4 concern when the turn shell becomes the writer.
  """

  @behaviour Normandy.Behaviours.SessionStore

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry

  @doc "Create a fresh ETS-backed store; returns the table id (handle)."
  @spec new(keyword()) :: :ets.tid()
  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :normandy_session_store)
    :ets.new(name, [:set, :public])
  end

  @impl true
  def append_entry(tid, session_id, %Entry{} = entry) do
    memory = lookup_memory(tid, session_id)
    id = entry.id || UUID.uuid4()
    entry = %{entry | id: id, parent_id: entry.parent_id || memory.head}
    memory = %{memory | entries: Map.put(memory.entries, id, entry), head: id}
    :ets.insert(tid, {{:session, session_id}, memory})
    {:ok, id}
  end

  @impl true
  def history(tid, session_id) do
    {:ok, tid |> lookup_memory(session_id) |> AgentMemory.entry_chain()}
  end

  @impl true
  def fork(tid, session_id, from_entry_id) do
    case :ets.lookup(tid, {:session, session_id}) do
      [] ->
        {:error, :no_such_session}

      [{_, %AgentMemory{} = memory}] ->
        case AgentMemory.fork(memory, from_entry_id) do
          {:error, reason} ->
            {:error, reason}

          {:ok, forked} ->
            new_id = UUID.uuid4()
            :ets.insert(tid, {{:session, new_id}, forked})
            {:ok, new_id}
        end
    end
  end

  @impl true
  def save_turn_state(tid, session_id, term) do
    :ets.insert(tid, {{:turn_state, session_id}, term})
    :ok
  end

  @impl true
  def load_turn_state(tid, session_id) do
    case :ets.lookup(tid, {:turn_state, session_id}) do
      [{_, term}] -> {:ok, term}
      [] -> :error
    end
  end

  defp lookup_memory(tid, session_id) do
    case :ets.lookup(tid, {:session, session_id}) do
      [{_, %AgentMemory{} = memory}] -> memory
      [] -> AgentMemory.new_memory()
    end
  end
end
