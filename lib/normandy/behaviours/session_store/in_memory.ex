defmodule Normandy.Behaviours.SessionStore.InMemory do
  @moduledoc """
  Process-backed in-memory `SessionStore` — the reference impl and default
  selection. Holds one `AgentMemory` per `session_id` plus an opaque turn-state
  map, in an `Agent`. Used for tests and library/single-node runs; not consumed by
  the turn loop in Phase 3.
  """

  @behaviour Normandy.Behaviours.SessionStore

  use Agent

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{sessions: %{}, turn_states: %{}, config_templates: %{}} end)
  end

  @doc "Start a fresh store and return its handle (pid)."
  @spec new(keyword()) :: pid()
  def new(opts \\ []) do
    {:ok, pid} = start_link(opts)
    pid
  end

  @impl true
  def append_entry(pid, session_id, %Entry{} = entry) do
    Agent.get_and_update(pid, fn state ->
      memory = Map.get(state.sessions, session_id, AgentMemory.new_memory())
      {id, memory} = put_entry(memory, entry)
      {{:ok, id}, put_in(state.sessions[session_id], memory)}
    end)
  end

  @impl true
  def history(pid, session_id) do
    Agent.get(pid, fn state ->
      case Map.get(state.sessions, session_id) do
        nil -> {:ok, []}
        %AgentMemory{} = memory -> {:ok, AgentMemory.entry_chain(memory)}
      end
    end)
  end

  @impl true
  def fork(pid, session_id, from_entry_id) do
    Agent.get_and_update(pid, fn state ->
      case Map.get(state.sessions, session_id) do
        nil ->
          {{:error, :no_such_session}, state}

        %AgentMemory{} = memory ->
          case AgentMemory.fork(memory, from_entry_id) do
            {:error, reason} ->
              {{:error, reason}, state}

            {:ok, forked} ->
              new_id = UUID.uuid4()
              {{:ok, new_id}, put_in(state.sessions[new_id], forked)}
          end
      end
    end)
  end

  @impl true
  def save_turn_state(pid, session_id, term) do
    Agent.update(pid, fn state -> put_in(state.turn_states[session_id], term) end)
  end

  @impl true
  def load_turn_state(pid, session_id) do
    Agent.get(pid, fn state ->
      case Map.fetch(state.turn_states, session_id) do
        {:ok, term} -> {:ok, term}
        :error -> :error
      end
    end)
  end

  @impl true
  def save_config_template(pid, session_id, tmpl) do
    Agent.update(pid, fn state -> put_in(state.config_templates[session_id], tmpl) end)
  end

  @impl true
  def load_config_template(pid, session_id) do
    Agent.get(pid, fn state ->
      case Map.fetch(state.config_templates, session_id) do
        {:ok, tmpl} -> {:ok, tmpl}
        :error -> :error
      end
    end)
  end

  @impl true
  def list_resumable(pid) do
    Agent.get(pid, fn state ->
      ids =
        for {sid, tmpl} <- state.config_templates,
            is_map(tmpl),
            Map.get(tmpl, :resume_policy) == :eager,
            do: sid

      {:ok, ids}
    end)
  end

  # Append an entry, minting an id and linking to the current head when absent.
  defp put_entry(%AgentMemory{} = memory, %Entry{} = entry) do
    id = entry.id || UUID.uuid4()
    entry = %{entry | id: id, parent_id: entry.parent_id || memory.head}
    {id, %{memory | entries: Map.put(memory.entries, id, entry), head: id}}
  end
end
