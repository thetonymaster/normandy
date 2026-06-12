defmodule Normandy.Behaviours.SessionStore do
  @moduledoc """
  Contract for externalizing a session's conversation entries and turn state.

  The memory-backing half (`append_entry`, `history`, `fork`) persists the
  parent-linked entry graph keyed by `session_id`. The turn-state half
  (`save_turn_state`, `load_turn_state`) round-trips an **opaque term** — defined
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
  """

  alias Normandy.Components.AgentMemory.Entry

  @type handle :: term()
  @type session_id :: String.t()

  @callback append_entry(handle(), session_id(), Entry.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback history(handle(), session_id()) :: {:ok, [Entry.t()]} | {:error, term()}
  @callback fork(handle(), session_id(), from_entry_id :: String.t()) ::
              {:ok, session_id()} | {:error, term()}
  @callback save_turn_state(handle(), session_id(), state :: term()) :: :ok | {:error, term()}
  @callback load_turn_state(handle(), session_id()) :: {:ok, term()} | :error
end
