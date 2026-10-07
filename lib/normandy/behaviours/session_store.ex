defmodule Normandy.Behaviours.SessionStore do
  @moduledoc """
  Contract for externalizing a session's conversation entries and turn state.

  The memory-backing half (`append_entry`, `history`, `fork`) persists the
  parent-linked entry graph keyed by `session_id`. The turn-state half
  (`save_turn_state/4`, `load_turn_state/2`) round-trips an **opaque term** — defined
  and contract-tested in Phase 3 but with no real consumer until Phase 4's
  `%TurnState{}` (suspendable turn / passivation).

  `handle` is impl-specific (a pid for `InMemory`, a table for `ETS`). Each impl
  exposes `new/0` (or `new/1`) returning a fresh handle for tests and callers.

  This seam persists the **full** entry graph: it deliberately does not apply
  `max_messages` windowing (that is a read-time / agent-runtime concern, applied
  by the turn loop in Phase 4, not at the persistence layer).

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

  alias Normandy.Components.AgentMemory.Entry

  @type handle :: term()
  @type session_id :: String.t()

  @callback append_entry(handle(), session_id(), Entry.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback history(handle(), session_id()) :: {:ok, [Entry.t()]} | {:error, term()}
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
  @callback load_turn_state(handle(), session_id()) :: {:ok, term()} | :error | {:error, term()}

  @callback save_config_template(handle(), session_id(), template :: term()) ::
              :ok | {:error, term()}
  @callback load_config_template(handle(), session_id()) ::
              {:ok, term()} | :error | {:error, term()}

  @doc """
  Lists the sessions with a turn in flight: those whose last `save_turn_state/4` had
  `inflight?: true`.

  Used by `Turn.ResumeReaper` on node-down to find the eager sessions to restart; the
  reaper still checks liveness (`whereis`) and the saved turn state, so a stale member
  is skipped. The cost follows the number of sessions in flight, not the number stored.
  """
  @callback list_resumable(handle()) :: {:ok, [session_id()]} | {:error, term()}

  @doc """
  Deletes a session: its turn state, its config template, its membership of the
  in-flight index and the entries of its history that no other session reaches.

  Idempotent: deleting a missing session is `:ok`. A fork keeps its history: on the
  backends that copy a fork's entries (InMemory, ETS, Redis) the session's own copy goes;
  on those that share ancestor entries between forks (Postgres, Mnesia) an entry stays
  while another session's history still reaches it. Deleting does not stop a live
  `Turn.Server`: stop it first.
  """
  @callback delete_session(handle(), session_id()) :: :ok | {:error, term()}
end
