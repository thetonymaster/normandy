defmodule Normandy.Agents.Turn.ResumeReaper do
  @moduledoc """
  Eager-handoff trigger for distributed sessions.

  `Horde.DynamicSupervisor` does NOT redistribute a node's children when that node
  dies (with `members: :auto` the dead member is removed from the CRDT, so the
  reclaim path never fires — see the Phase-7 design §7.6). This reaper provides
  *selective* eager handoff instead: it monitors cluster nodes and, on `:nodedown`,
  restarts the `:eager` sessions whose server died with the lost node.

  A session is reaped when it is (1) `:eager` (`SessionStore.list_resumable/1`),
  (2) not currently registered anywhere (`SessionRegistry.whereis/2 == :none`), and
  (3) has a **non-terminal** persisted turn state. It is restarted as a thin spec
  under the supervisor, where `Turn.Server.init/1` reconstructs config from the
  persisted template and `Turn.resume/1`s the in-flight turn — no inbound request.

  Run one reaper per node (host supervision tree). Concurrent reapers on multiple
  survivors are safe: the registry's atomic `:via` registration means only one
  start wins; the losers get `{:error, {:already_started, _}}`, treated as success.
  """
  use GenServer
  require Logger

  alias Normandy.Agents.Turn

  @type opts :: [
          name: GenServer.name(),
          store: {module(), term()},
          registry: {module(), term()},
          supervisor: term(),
          supervisor_mod: module(),
          template_provider: {module(), term()}
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    :ok = :net_kernel.monitor_nodes(true)

    state = %{
      store: Keyword.fetch!(opts, :store),
      registry: Keyword.fetch!(opts, :registry),
      supervisor: Keyword.fetch!(opts, :supervisor),
      supervisor_mod: Keyword.get(opts, :supervisor_mod, Normandy.Agents.Turn.Supervisor.Horde),
      template_provider: Keyword.fetch!(opts, :template_provider)
    }

    {:ok, state}
  end

  # `:net_kernel.monitor_nodes/1` delivers `{:nodedown, node}` (and `{:nodeup, node}`).
  @impl true
  def handle_info({:nodedown, _node}, state) do
    reap(state)
    {:noreply, state}
  end

  def handle_info({:nodedown, _node, _info}, state) do
    reap(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Restart every eager, unregistered, non-terminal session under the supervisor.
  Exposed (not private) so it can be unit-tested without orchestrating real nodes.
  """
  @spec reap(map()) :: :ok
  def reap(state) do
    {store_mod, store_handle} = state.store
    {reg_mod, reg_handle} = state.registry

    case store_mod.list_resumable(store_handle) do
      {:ok, sids} ->
        Enum.each(sids, fn sid ->
          if reg_mod.whereis(reg_handle, sid) == :none and
               non_terminal?(store_mod, store_handle, sid) do
            start_session(state, sid)
          end
        end)

      {:error, reason} ->
        # Don't let a store failure silently suppress eager handoff on :nodedown —
        # surface it so operators can detect and triage missed reaps.
        Logger.warning("ResumeReaper: list_resumable failed: #{inspect(reason)}")
        :ok
    end
  end

  defp non_terminal?(store_mod, store_handle, sid) do
    case store_mod.load_turn_state(store_handle, sid) do
      {:ok, %Turn.State{status: status}} -> status not in [:stopped, :failed]
      _ -> false
    end
  end

  defp start_session(state, sid) do
    opts = [
      session_id: sid,
      store: state.store,
      registry: state.registry,
      template_provider: state.template_provider,
      resume_policy: :eager
    ]

    # Race-safe: a concurrent reaper on another survivor may start the same session;
    # the registry's atomic registration makes the loser get {:error, {:already_started, _}}.
    # Surface genuinely unexpected failures rather than swallowing them silently.
    case state.supervisor_mod.start_server(state.supervisor, opts) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("ResumeReaper: failed to resume #{sid}: #{inspect(reason)}")

      other ->
        Logger.warning(
          "ResumeReaper: unexpected start_server result for #{sid}: #{inspect(other)}"
        )
    end
  end
end
