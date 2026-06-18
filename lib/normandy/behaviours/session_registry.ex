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

  @doc """
  Returns the `name` a `Turn.Server` should start under for atomic registration.

  `:self_register` keeps the historical path (the server calls `register/3` in
  `init`). A `{:via, module, term}` tuple makes the process register at start
  (used by distributed impls), which closes the start-time race. Optional: callers
  fall back to `:self_register` when an impl does not export it.
  """
  @callback child_name(handle(), session_id()) :: {:via, module(), term()} | :self_register
  @optional_callbacks child_name: 2
end
