defmodule Normandy.Behaviours.SessionStore.InMemory do
  @moduledoc """
  Process-backed in-memory `SessionStore` — the reference impl and default
  selection. Holds one `AgentMemory` per `session_id` plus an opaque turn-state
  map, in an `Agent`. Used for tests and library/single-node runs.
  """

  @behaviour Normandy.Behaviours.SessionStore

  use Agent

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Options

  @no_opts_schema NimbleOptions.new!([])

  @doc """
  Starts a store.

  ## Options

  None; any key raises `ArgumentError`.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    [] = Options.validate!(opts, @no_opts_schema, {__MODULE__, :start_link, 1})

    Agent.start_link(fn ->
      %{sessions: %{}, turn_states: %{}, config_templates: %{}, inflight: MapSet.new()}
    end)
  end

  @doc """
  Starts a fresh store and returns its handle (a pid).

  ## Options

  None; any key raises `ArgumentError`.
  """
  @spec new(keyword()) :: pid()
  def new(opts \\ []) do
    [] = Options.validate!(opts, @no_opts_schema, {__MODULE__, :new, 1})
    {:ok, pid} = start_link()
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
  def history_since_compaction(pid, session_id) do
    Agent.get(pid, fn state ->
      case Map.get(state.sessions, session_id) do
        nil ->
          {:ok, []}

        %AgentMemory{} = memory ->
          {:ok, memory |> AgentMemory.entry_chain() |> AgentMemory.since_last_compaction()}
      end
    end)
  end

  @impl true
  def fork(pid, session_id, from_entry_id) do
    Agent.get_and_update(pid, fn state ->
      with %AgentMemory{} = memory <- Map.get(state.sessions, session_id, :no_such_session),
           {:ok, forked} <- AgentMemory.fork(memory, from_entry_id) do
        new_id = UUID.uuid4()
        # Only the chain the fork's head reaches: the parent's later entries stay
        # the parent's, so deleting it removes them.
        chain = AgentMemory.entry_chain(forked)
        forked = %{forked | entries: Map.new(chain, &{&1.id, &1})}
        {{:ok, new_id}, put_in(state.sessions[new_id], forked)}
      else
        :no_such_session -> {{:error, :no_such_session}, state}
        {:error, reason} -> {{:error, reason}, state}
      end
    end)
  end

  @impl true
  def save_turn_state(pid, session_id, term, inflight?) when is_boolean(inflight?) do
    Agent.update(pid, fn state ->
      inflight =
        if inflight?,
          do: MapSet.put(state.inflight, session_id),
          else: MapSet.delete(state.inflight, session_id)

      %{state | turn_states: Map.put(state.turn_states, session_id, term), inflight: inflight}
    end)
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
    Agent.get(pid, fn state -> {:ok, MapSet.to_list(state.inflight)} end)
  end

  @impl true
  def delete_session(pid, session_id) do
    Agent.update(pid, fn state ->
      %{
        state
        | sessions: Map.delete(state.sessions, session_id),
          turn_states: Map.delete(state.turn_states, session_id),
          config_templates: Map.delete(state.config_templates, session_id),
          inflight: MapSet.delete(state.inflight, session_id)
      }
    end)
  end

  # Append an entry, minting an id and linking to the current head when absent.
  defp put_entry(%AgentMemory{} = memory, %Entry{} = entry) do
    id = entry.id || UUID.uuid4()
    entry = %{entry | id: id, parent_id: entry.parent_id || memory.head}
    {id, %{memory | entries: Map.put(memory.entries, id, entry), head: id}}
  end
end
