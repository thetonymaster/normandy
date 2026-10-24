defmodule Normandy.Behaviours.SessionRegistry do
  @moduledoc """
  Maps a `session_id` to the live `Turn.Server` pid serving it, so a router can
  decide route-to-existing vs rehydrate-and-start. `:none` means no live process
  (the session may still have persisted state in a `SessionStore`). A lookup that
  could not be made (a backend outage) is `{:error, reason}`, never `:none`:
  taking it for "no process" would start a second server for a live session.

  The default `Native` impl wraps Elixir's built-in `Registry` (O(1) lookup,
  auto-unregister on owner death). `Horde` and `Redis` are the distributed impls.

  Every impl must pass the ExUnit suite `Normandy.Test.SessionRegistryContract`.
  """

  @type handle :: term()
  @type session_id :: String.t()

  @doc """
  Returns `{:ok, pid}` for the live `Turn.Server` of `session_id`, `:none` when there is
  none, or `{:error, reason}` when the backend cannot answer.

  Never answer `:none` for an outage: the router would start a second server for a live
  session. A `{:error, reason}` is returned to the caller of `Turn.Session.run/2`, and
  `Turn.ResumeReaper` skips that session.
  """
  @callback whereis(handle(), session_id()) :: {:ok, pid()} | :none | {:error, term()}
  @doc """
  Registers `pid` under `session_id` and returns `:ok`, or `{:error, :taken}` when a live
  process already holds it.

  `Turn.Server` calls it from its own `init` with `self()` when `child_name/2` returns
  `:self_register`, then looks the holder up with `whereis/2` and stops with
  `{:already_started, holder}`. The registration ends when the process dies.
  """
  @callback register(handle(), session_id(), pid()) :: :ok | {:error, :taken}
  @doc """
  Frees `session_id` and returns `:ok`; it is `:ok` for an id that is not registered.

  `Turn.Server` does not call it: a registration ends when its process dies, which every
  implementation must do on its own. The Redis implementation calls it from its via module,
  when a start under a via name fails.
  """
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
