defmodule Normandy.Agents.Turn.ServerSupervisor do
  @moduledoc """
  The contract of the module a `Normandy.Agents.Turn.Session` starts and stops its
  `Turn.Server` through (its `:supervisor_mod`).

  `Normandy.Agents.Turn.Supervisor` (one node) and `Normandy.Agents.Turn.Supervisor.Horde`
  (a cluster) implement it. `Turn.Session.new/1` refuses a `:supervisor_mod` that does not
  export both callbacks, naming the option; `Turn.ResumeReaper` and
  `Normandy.Coordination.AgentProcess` start servers through the same module.
  """

  @doc """
  Starts a `Turn.Server` with `server_opts` (the options of
  `Normandy.Agents.Turn.Server.start_link/1`) under `supervisor`.

  Returns what `DynamicSupervisor.start_child/2` returns: `{:ok, pid}` or
  `{:error, reason}` in practice. A server already registered for the
  session is `{:error, {:already_started, pid}}` (bare or nested in the supervisor's
  error); the session routes to `pid` (see "Start-time race" in
  `Normandy.Agents.Turn.Session`).
  """
  @callback start_server(supervisor :: term(), server_opts :: keyword()) ::
              DynamicSupervisor.on_start_child()

  @doc """
  Stops the session server `pid`, a child of `supervisor`, without a restart. Returns
  `{:error, :not_found}` when `supervisor` has no such child. `Turn.Session.delete/1`
  calls it.
  """
  @callback stop_server(supervisor :: term(), pid()) :: :ok | {:error, :not_found}
end
