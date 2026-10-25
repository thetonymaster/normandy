defmodule Normandy.Behaviours.SessionStore do
  @moduledoc """
  Contract for externalizing a session's conversation entries and turn state.

  The memory-backing half (`append_entry`, `history`, `fork`) persists the
  parent-linked entry graph keyed by `session_id`. The turn-state half
  (`save_turn_state/4`, `load_turn_state/2`) round-trips an **opaque term**, which
  `Turn.Server` uses to suspend and resume a turn (passivation).

  `handle` is impl-specific (a pid for `InMemory`, a table for `ETS`). The in-process
  impls expose `new/0` (or `new/1`) returning a fresh handle; `Redis.new/1` requires
  `:url` and `:namespace`; for `Postgres` the handle is the host's Repo module (no
  constructor).

  Every impl must pass the ExUnit suite `Normandy.Test.SessionStoreContract`.

  This seam persists the **full** entry graph: it deliberately does not apply
  `max_messages` windowing (that is a read-time / agent-runtime concern, applied
  by the turn loop, not at the persistence layer).

  Missing-session semantics are asymmetric by intent: `history/2` is lenient and
  returns `{:ok, []}` for an unknown session, while `fork/3` is strict and returns
  `{:error, _}` — you cannot branch a conversation that does not exist.

  `load_turn_state/2` and `load_config_template/2` return `:error` only when
  nothing is saved for the session. A backend failure (a timeout, a lost
  connection, an aborted transaction) is `{:error, reason}`: `Turn.Server` waits
  `:unavailable` and retries, replying the reason to `run/2`, because starting as
  if nothing were saved would drop an in-flight turn and the next save would
  overwrite it.
  """

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry

  @type handle :: term()
  @type session_id :: String.t()

  @doc """
  Appends `entry` to the session's history and returns `{:ok, entry_id}`.

  `entry_id` is the entry's own `id`, or a new one when it is `nil`. An entry with no
  `parent_id` goes after the session's current head, and a session that does not exist yet
  is created. `Turn.Server` calls it for every message and for each compaction. A store
  error is `{:error, reason}`; for a message the turn fails with a `:persist_failed`
  `Normandy.TurnError`, and a failed compaction entry is logged and the turn goes on.
  """
  @callback append_entry(handle(), session_id(), Entry.t()) ::
              {:ok, String.t()} | {:error, term()}
  @doc """
  Returns `{:ok, entries}`, the session's active branch from the oldest entry to the head.

  An unknown session is `{:ok, []}`. The full branch comes back: `max_messages` is not
  applied. `Turn.Server` rebuilds the memory from it (`AgentMemory.from_entries/1`) when it
  loads a session; `{:error, reason}` makes the server wait `:unavailable` and retry.
  """
  @callback history(handle(), session_id()) :: {:ok, [Entry.t()]} | {:error, term()}
  @doc """
  Optional. Returns `{:ok, entries}`, the session's active branch from its last
  `"compaction"` entry to the head, or the whole branch when it has none.

  `Turn.Server` stores a snapshot of the whole conversation at each compaction, and
  `AgentMemory.from_entries/1` reads only the last one and what follows it, so this is all
  a restore needs: a store that reads nothing older than that entry lets a session's load
  time follow its last context window rather than its number of compactions. `restore_history/3` calls it, and
  falls back to `c:history/2` for a store that does not export it. An unknown session is
  `{:ok, []}`; a failure is `{:error, reason}`, as for `c:history/2`.
  """
  @callback history_since_compaction(handle(), session_id()) ::
              {:ok, [Entry.t()]} | {:error, term()}
  @doc """
  Creates a new session whose history is the branch of `session_id` up to `from_entry_id`,
  and returns `{:ok, new_session_id}`.

  The original keeps its own history. A session that does not exist is
  `{:error, :no_such_session}`, and an entry that is not on the session's branch is
  `{:error, :no_such_entry}`. The new session has no turn state or config template. Normandy
  does not call it; it is for hosts that branch a conversation.
  """
  @callback fork(handle(), session_id(), from_entry_id :: String.t()) ::
              {:ok, session_id()} | {:error, term()}
  @doc """
  Saves the session's turn state and, in the same write, whether its turn is in flight.

  `inflight?` is what `Turn.Server` computes: the session is `:eager` and its turn has
  not ended (status other than `:stopped` and `:failed`). `list_resumable/1` lists the
  sessions whose last save had `inflight?: true`. The two are written together, so the
  index never disagrees with the saved state; a backend that cannot write both
  atomically may leave a session listed that is not in flight (the reaper re-checks the
  turn state), never the reverse.
  """
  @callback save_turn_state(handle(), session_id(), state :: term(), inflight? :: boolean()) ::
              :ok | {:error, term()}
  @doc """
  Returns `{:ok, state}`, the term the last `save_turn_state/4` saved for the session.

  `:error` means nothing is saved. A backend failure is `{:error, reason}`, never `:error`:
  `Turn.Server` waits `:unavailable` and retries on it, but starts a session with no saved
  state on `:error`.
  """
  @callback load_turn_state(handle(), session_id()) :: {:ok, term()} | :error | {:error, term()}

  @doc """
  Saves `template` for the session, replacing an earlier one, and returns `:ok`.

  The template is the plain-data map `Normandy.Agents.ConfigTemplate.from_config/3` builds,
  plus the session's `:server_options`. `Turn.Session.run/2` saves it when it starts a
  server for a session that has a `:config` and a `:template_provider`. Treat it as an
  opaque term and return it unchanged from `load_config_template/2`. `{:error, reason}` is
  returned by that `run/2`.
  """
  @callback save_config_template(handle(), session_id(), template :: term()) ::
              :ok | {:error, term()}
  @doc """
  Returns `{:ok, template}`, the term the last `save_config_template/3` saved.

  `Turn.Session.run/2` and `Turn.Server` read it to rebuild a session's config. `:error`
  means no template is saved: `run/2` then returns a `:session_unavailable`
  `Normandy.TurnError` with reason `{:no_config_template, session_id}`. A backend failure
  is `{:error, reason}`, never `:error`.
  """
  @callback load_config_template(handle(), session_id()) ::
              {:ok, term()} | :error | {:error, term()}

  @doc """
  Lists the sessions with a turn in flight: those whose last `save_turn_state/4` had
  `inflight?: true`.

  Used by `Turn.ResumeReaper` on node-down to find the eager sessions to restart; the
  reaper still checks liveness (`whereis`) and the saved turn state, so a stale member
  is skipped. On the InMemory, ETS, Postgres and Redis stores the cost follows the number
  of sessions in flight, not the number stored; the Mnesia store scans every session row.
  """
  @callback list_resumable(handle()) :: {:ok, [session_id()]} | {:error, term()}

  @doc """
  Deletes a session: its turn state, its config template, its membership of the
  in-flight index and the entries it wrote that no other session reaches, including a
  branch its head left (an append with an explicit `parent_id`).

  Idempotent: deleting a missing session is `:ok`. A fork keeps its history: on the
  backends that copy a fork's entries (InMemory, ETS, Redis) the session's own copy goes;
  on those that share ancestor entries between forks (Postgres, Mnesia) an entry stays
  while another session's history still reaches it, and concurrent deletes of sessions
  that share entries must not both keep them. Deleting does not stop a live
  `Turn.Server`; `Normandy.Agents.Turn.Session.delete/1` does both.
  """
  @callback delete_session(handle(), session_id()) :: :ok | {:error, term()}

  @optional_callbacks history_since_compaction: 2

  @doc """
  The entries a restore rebuilds a session's memory from (`AgentMemory.from_entries/1`):
  `store`'s `c:history_since_compaction/2` when it exports one, else `c:history/2`. Both
  rebuild the same memory. `restore_memory/4` builds on it.
  """
  @spec restore_history(module(), handle(), session_id()) ::
          {:ok, [Entry.t()]} | {:error, term()}
  def restore_history(store, handle, session_id) when is_atom(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :history_since_compaction, 2),
      do: store.history_since_compaction(handle, session_id),
      else: store.history(handle, session_id)
  end

  @doc """
  A session's memory rebuilt from `store`: `restore_history/3`'s entries through
  `AgentMemory.from_entries/1`, capped at `max_messages` (the rebuilt memory is
  otherwise uncapped), with the tool-loop count the stored history records for its last
  turn (`{turn_id, n}` or `nil`), for a resume. `Turn.Server` and
  `Normandy.Coordination.AgentProcess` call it.

  Never raises, exits or throws. A store call that exits is
  `{:error, {:store_exit, reason}}`, one that raises or throws
  `{:error, {:store_raised, exception}}`, and a history `from_entries/1` refuses (a
  snapshot version a newer node wrote) `{:error, {:invalid_history, %ArgumentError{}}}`,
  whose message names entry ids and types, never content. A store's own
  `{:error, reason}` is returned as it is.
  """
  @spec restore_memory(module(), handle(), session_id(), pos_integer() | nil) ::
          {:ok, AgentMemory.t(), {String.t() | nil, non_neg_integer()} | nil}
          | {:error, term()}
  def restore_memory(store, handle, session_id, max_messages) when is_atom(store) do
    with {:ok, entries} <- call_store(fn -> restore_history(store, handle, session_id) end),
         {:ok, memory} <- rebuild(entries) do
      {:ok, %{memory | max_messages: max_messages}, AgentMemory.stored_turn_rounds(entries)}
    end
  end

  defp call_store(fun) do
    fun.()
  catch
    :exit, reason ->
      {:error, {:store_exit, reason}}

    :throw, value ->
      {:error, {:store_raised, %ErlangError{original: {:nocatch, value}}}}

    :error, reason ->
      {:error, {:store_raised, Exception.normalize(:error, reason, __STACKTRACE__)}}
  end

  defp rebuild(entries) do
    {:ok, AgentMemory.from_entries(entries)}
  rescue
    e in ArgumentError -> {:error, {:invalid_history, e}}
  end
end
