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

  The restarted server restores the plain-data options saved with the template
  (`:approval_timeout_ms`, `:on_approval_timeout`, `:idle_timeout_ms`). Functions
  and pids can't be saved, so pass `:subscriber` and `:handlers` to the reaper; it
  forwards them to every session it restarts. Without them, a revived session runs
  the default handlers and has no subscriber to tell about a pending approval.

  Run one reaper per node (host supervision tree). Concurrent reapers on multiple
  survivors are safe: the registry's atomic `:via` registration means only one
  start wins; the losers get `{:error, {:already_started, _}}`, treated as success.
  """
  use GenServer
  require Logger

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Start
  alias Normandy.Options

  @type opts :: [
          name: GenServer.name(),
          store: {module(), term()},
          registry: {module(), term()},
          supervisor: term(),
          supervisor_mod: module(),
          template_provider: {module(), term()},
          subscriber: (atom(), map() -> any()) | nil,
          handlers: Turn.Driver.Handlers.t() | nil
        ]

  # The reaper passes :store, :registry, :template_provider, :subscriber and :handlers to
  # Turn.Server.start_link/1 on every reap, so it takes the types the server takes (which
  # are Turn.Session.new/1's, ruling P4): a value the server would reject raises here, not
  # later in the reaper process.
  @server_types Map.new(Turn.Server.__opts_schema__(:start_link).schema, fn {key, spec} ->
                  {key, Keyword.fetch!(spec, :type)}
                end)

  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the reaper."],
                            store: [
                              type: @server_types.store,
                              required: true,
                              doc:
                                "The `SessionStore` as `{module, handle}`; its " <>
                                  "`list_resumable/1` names the `:eager` sessions."
                            ],
                            registry: [
                              type: @server_types.registry,
                              required: true,
                              doc: "The `SessionRegistry` as `{module, handle}`."
                            ],
                            supervisor: [
                              type: :any,
                              required: true,
                              doc: "The supervisor sessions restart under (its name, for Horde)."
                            ],
                            supervisor_mod: [
                              type: :atom,
                              default: Normandy.Agents.Turn.Supervisor.Horde,
                              doc: "The module whose `start_server/2` restarts a session."
                            ],
                            template_provider: [
                              type: @server_types.template_provider,
                              type_doc: "`{module, handle}`",
                              required: true,
                              doc: "The `AgentTemplate` as `{module, handle}` (thin starts)."
                            ],
                            subscriber: [
                              type: @server_types.subscriber,
                              doc: "Passed to every session the reaper restarts."
                            ],
                            handlers: [
                              type: @server_types.handlers,
                              type_doc: "a `Normandy.Agents.Turn.Driver.Handlers` or `nil`",
                              doc: "Passed to every session the reaper restarts."
                            ]
                          )

  @doc """
  Starts the reaper.

  ## Options

  #{Options.docs(@start_link_opts_schema)}
  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

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
      supervisor_mod: Keyword.fetch!(opts, :supervisor_mod),
      template_provider: Keyword.fetch!(opts, :template_provider),
      # Functions and pids can't be saved with the session, so the host supplies
      # them here for every session this reaper restarts.
      host_server_opts: Keyword.take(opts, [:subscriber, :handlers])
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
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          if not_running?(reg_mod, reg_handle, sid) and
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

  # Only a registry that answers "no process" counts; a failed lookup skips the
  # session (starting it could make a second server) and logs the missed reap.
  defp not_running?(reg_mod, reg_handle, sid) do
    case reg_mod.whereis(reg_handle, sid) do
      :none ->
        true

      {:ok, _pid} ->
        false

      {:error, reason} ->
        Logger.warning(
          "ResumeReaper: could not look up #{inspect(sid)} in the registry: #{inspect(reason)}"
        )

        false
    end
  end

  defp non_terminal?(store_mod, store_handle, sid) do
    case store_mod.load_turn_state(store_handle, sid) do
      {:ok, %Turn.State{status: status}} ->
        status not in [:stopped, :failed]

      {:error, reason} ->
        # A lazy caller can still rehydrate the session later; log the missed reap.
        Logger.warning(
          "ResumeReaper: could not load the turn state of #{inspect(sid)}: #{inspect(reason)}"
        )

        false

      _ ->
        false
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

    # reap/1 is public and callers may build `state` by hand, so the key is optional.
    opts = opts ++ Map.get(state, :host_server_opts, [])

    # Race-safe: a concurrent reaper on another survivor may start the same session, and
    # Horde's via registration can lag; Turn.Start routes to the winner or retries.
    # Surface genuinely unexpected failures rather than swallowing them silently.
    case Start.start_server(state.supervisor_mod, state.supervisor, opts, state.registry, sid) do
      {:ok, _pid} ->
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
