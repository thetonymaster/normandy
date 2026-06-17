defmodule Normandy.Behaviours.SessionRegistry do
  @moduledoc """
  Maps a `session_id` to the live `Turn.Server` pid serving it, so a router can
  decide route-to-existing vs rehydrate-and-start. `:none` means no live process
  (the session may still have persisted state in a `SessionStore`).

  The default `Native` impl wraps Elixir's built-in `Registry` (O(1) lookup,
  auto-unregister on owner death). Distributed impls (Horde/syn) are deferred.
  """

  @type handle :: term()
  @type session_id :: String.t()

  @callback whereis(handle(), session_id()) :: {:ok, pid()} | :none
  @callback register(handle(), session_id(), pid()) :: :ok | {:error, :taken}
  @callback unregister(handle(), session_id()) :: :ok
end
