defmodule Normandy.Coordination.AgentProcess do
  @moduledoc """
  GenServer wrapper for running BaseAgent instances as supervised processes.

  AgentProcess enables agents to run as long-lived processes that can:
  - Maintain state across multiple invocations
  - Be supervised and restarted on failure
  - Receive messages asynchronously
  - Integrate with process registries

  ## Example

      # Start an agent process
      {:ok, pid} = AgentProcess.start_link(
        agent: my_agent,
        name: :research_agent
      )

      # Execute synchronously
      {:ok, result} = AgentProcess.run(pid, "Analyze this data")

      # Execute asynchronously
      :ok = AgentProcess.cast(pid, "Process in background", reply_to: self())

      # Get current agent state
      agent = AgentProcess.get_agent(pid)

  ## Inline turns (the default)

  With `turn_engine: :inline`, runs, casts and `update_agent/2` calls go through one FIFO
  queue and execute one at a time, each turn in a worker process started from the config
  the previous one left. The process itself never waits on a turn: `get_agent/1` (the
  config as of the last finished turn), `get_id/1`, `get_stats/1` and `approve/2` answer
  at once while a turn runs. A run whose caller died while it waited in the queue is
  skipped. The worker dies with the process (`stop/1` kills a turn in flight); a worker
  killed from outside replies a `:task_down` `Normandy.TurnError`.

  ## Durable turn engine (`:server` mode)

  Pass `turn_engine: :server` to route turns through the durable
  `Normandy.Agents.Turn.Session`/`Turn.Server` engine (approval parking,
  passivation, persistence) instead of the default synchronous `:inline`
  `BaseAgent.run/2` path. `:inline` is the default and is unchanged.

      {:ok, pid} = AgentProcess.start_link(agent: config, turn_engine: :server)

  In `:server` mode:

  - `run/3`/`cast/3` route through `Turn.Session`; `run/3` is non-blocking
    internally (the GenServer stays responsive while a turn is parked);
    `approve/2` delivers human-approval decisions to a parked turn.
  - The `SessionStore` owns conversation memory: `get_agent/1` reconstructs it
    from the store, and `update_agent/2` updates only the config template
    (model/temperature/behaviours/tools) — memory mutations are ignored.
  - Session infra (`:store`, `:registry`, `:supervisor`) may be supplied via
    `start_link`; if omitted, the process starts and owns in-memory defaults
    that terminate with it. `start_link` builds one `Turn.Session` from them and from
    `:supervisor_mod`, `:template_provider`, `:template_id`, `:resume_policy`,
    `:subscriber`, `:handlers`, `:approval_timeout_ms`, `:on_approval_timeout` and
    `:idle_timeout_ms` (see `Turn.Session.new/1`; `start_link/1` checks them with its types);
    `update_agent/2` gives it the new config for the next server start.
  """

  use GenServer
  require Logger

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Options
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.TurnError
  alias Normandy.WatchedWorker

  @agent_id_key :"$normandy_agent_id"

  # The :server-mode keys go to Turn.Session.new/1 in init/1; its schema is the single
  # source of their types (ruling P4), so a value accepted here cannot fail there and
  # crash init/1 (Review Focus 3). Types only: Session's required/default flags do not apply.
  @session_types Map.new(Turn.Session.__opts_schema__(:new).schema, fn {key, spec} ->
                   {key, Keyword.fetch!(spec, :type)}
                 end)

  # The session keys init/1 passes on untouched: all of Session's but the ones it builds
  # itself (the id, the config and the infra it may start and own).
  @session_options Map.keys(@session_types) --
                     [:session_id, :config, :store, :registry, :supervisor]

  @type agent_id :: String.t()
  @type run_opts :: [timeout: timeout()]

  # Client API

  @start_link_opts_schema NimbleOptions.new!(
                            agent: [
                              type: {:struct, Normandy.Agents.BaseAgentConfig},
                              required: true,
                              type_doc: "a `%Normandy.Agents.BaseAgentConfig{}`",
                              doc: "The agent config the process runs."
                            ],
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the process."],
                            agent_id: [
                              type: :string,
                              doc:
                                "The agent's id (default: a new UUID). In `:server` mode it is " <>
                                  "also the session id."
                            ],
                            context_pid: [
                              type: {:or, [:pid, :atom]},
                              doc:
                                "A `Normandy.Coordination.StatefulContext` process, kept in the " <>
                                  "agent's state."
                            ],
                            turn_engine: [
                              type: {:in, [:inline, :server]},
                              default: :inline,
                              doc:
                                "`:inline` runs `BaseAgent.run/2` in this process; `:server` " <>
                                  "routes turns through `Turn.Session`/`Turn.Server` (approval " <>
                                  "parking, passivation, persistence)."
                            ],
                            store: [
                              type: @session_types.store,
                              type_doc: "`{module, handle}`",
                              doc:
                                "`:server` mode: the `SessionStore` as `{module, handle}`. " <>
                                  "Without it the process starts and owns an in-memory store."
                            ],
                            registry: [
                              type: @session_types.registry,
                              type_doc: "`{module, handle}`",
                              doc:
                                "`:server` mode: the `SessionRegistry` as `{module, handle}`. " <>
                                  "Without it the process starts and owns a `Native` registry."
                            ],
                            supervisor: [
                              type: @session_types.supervisor,
                              type_doc: "a pid or a supervisor name",
                              doc:
                                "`:server` mode: the session supervisor. Without it the process " <>
                                  "starts and owns a `Turn.Supervisor`."
                            ],
                            supervisor_mod: [
                              type: @session_types.supervisor_mod,
                              doc:
                                "`:server` mode: the module whose `start_server/2` starts " <>
                                  "sessions (default `Normandy.Agents.Turn.Supervisor`)."
                            ],
                            template_provider: [
                              type: @session_types.template_provider,
                              type_doc: "`{module, handle}`",
                              doc: "`:server` mode: the `AgentTemplate` as `{module, handle}`."
                            ],
                            resume_policy: [
                              type: @session_types.resume_policy,
                              doc:
                                "`:server` mode: the session's resume policy (default `:lazy`)."
                            ],
                            template_id: [
                              type: @session_types.template_id,
                              doc: "`:server` mode: the template id (default: the config's name)."
                            ],
                            subscriber: [
                              type: @session_types.subscriber,
                              doc: "`:server` mode: passed to `Turn.Server.start_link/1`."
                            ],
                            handlers: [
                              type: @session_types.handlers,
                              type_doc: "a `Normandy.Agents.Turn.Driver.Handlers` or `nil`",
                              doc: "`:server` mode: passed to `Turn.Server.start_link/1`."
                            ],
                            approval_timeout_ms: [
                              type: @session_types.approval_timeout_ms,
                              doc: "`:server` mode: passed to `Turn.Server.start_link/1`."
                            ],
                            on_approval_timeout: [
                              type: @session_types.on_approval_timeout,
                              doc: "`:server` mode: passed to `Turn.Server.start_link/1`."
                            ],
                            idle_timeout_ms: [
                              type: @session_types.idle_timeout_ms,
                              doc: "`:server` mode: passed to `Turn.Server.start_link/1`."
                            ]
                          )

  @run_opts_schema NimbleOptions.new!(
                     timeout: [
                       type: :timeout,
                       default: :infinity,
                       doc:
                         "How long the caller waits for the reply, in ms. A run is bounded " <>
                           "by its retries, tool timeouts and `max_tool_iterations`, so the " <>
                           "default waits for it, as `Turn.Server.run/2` does."
                     ]
                   )

  @update_agent_opts_schema NimbleOptions.new!(
                              timeout: [
                                type: :timeout,
                                default: :infinity,
                                doc:
                                  "How long the caller waits for the reply, in ms. In `:inline` " <>
                                    "mode the update waits behind the turn in flight, so the " <>
                                    "default waits for it, as `run/3` does. The bound is on the " <>
                                    "wait: an update the caller stopped waiting for still applies."
                              ]
                            )

  @cast_opts_schema NimbleOptions.new!(
                      reply_to: [
                        type: {:or, [:pid, :atom]},
                        doc:
                          "Where to send `{:agent_result, agent_id, result}` when the run ends."
                      ]
                    )

  @doc false
  @spec __opts_schema__(:start_link | :run | :update_agent) :: NimbleOptions.t()
  def __opts_schema__(:start_link), do: @start_link_opts_schema
  def __opts_schema__(:run), do: @run_opts_schema
  def __opts_schema__(:update_agent), do: @update_agent_opts_schema

  @doc """
  Starts an AgentProcess GenServer.

  ## Options

  #{Options.docs(@start_link_opts_schema)}

  ## Example

      {:ok, pid} = AgentProcess.start_link(
        agent: my_agent,
        name: :my_agent,
        agent_id: "agent_1"
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})
    check_session_agent_id!(opts)

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  # In :server mode the agent id is the session id (init/1), so it must obey Session's rule
  # now, not crash init/1. Other engines accept any string.
  defp check_session_agent_id!(opts) do
    with :server <- Keyword.fetch!(opts, :turn_engine),
         {:ok, id} <- Keyword.fetch(opts, :agent_id),
         {:error, message} <- Turn.Session.validate_session_id(id) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.start_link/1: invalid value for :agent_id option " <>
              "(the session id under turn_engine: :server): " <> message
    else
      _ok_or_not_applicable -> :ok
    end
  end

  @doc """
  Executes the agent synchronously.

  Runs the agent with the given input and returns the result.

  ## Options

  #{Options.docs(@run_opts_schema)}

  ## Example

      {:ok, result} = AgentProcess.run(pid, "What is AI?")
  """
  @spec run(GenServer.server(), term(), run_opts()) :: {:ok, term()} | {:error, Exception.t()}
  def run(server, input, opts \\ []) do
    opts = Options.validate!(opts, @run_opts_schema, {__MODULE__, :run, 3})
    GenServer.call(server, {:run, input, OtelCtx.capture()}, Keyword.fetch!(opts, :timeout))
  end

  @doc """
  Executes the agent asynchronously.

  The agent runs in the background. If `:reply_to` is provided,
  sends `{:agent_result, agent_id, result}` when complete.

  ## Options

  #{Options.docs(@cast_opts_schema)}

  ## Example

      :ok = AgentProcess.cast(pid, input, reply_to: self())

      receive do
        {:agent_result, agent_id, result} ->
          IO.inspect(result)
      end
  """
  @spec cast(GenServer.server(), term(), keyword()) :: :ok
  def cast(server, input, opts \\ []) do
    opts = Options.validate!(opts, @cast_opts_schema, {__MODULE__, :cast, 3})
    reply_to = Keyword.get(opts, :reply_to)
    GenServer.cast(server, {:run_async, input, reply_to, OtelCtx.capture()})
  end

  @doc """
  Delivers approval decisions to a turn parked awaiting human approval
  (`:server` mode only). `decisions` maps `tool_call_id` to `:approve | :reject`;
  any parked id absent or `:reject` is treated as rejected (fail-closed).

  Returns `:ok`; with no live parked session, `{:error, %Normandy.TurnError{type:
  :session_unavailable, reason: :no_session}}` (see `Normandy.Agents.Turn.Session.approve/2`);
  `{:error, :inline_mode}` when the process runs in `:inline` mode.
  """
  @spec approve(GenServer.server(), %{optional(String.t()) => :approve | :reject}) ::
          :ok | {:error, TurnError.t()} | {:error, :inline_mode}
  def approve(server, decisions) do
    GenServer.call(server, {:approve, decisions})
  end

  @doc """
  Returns the current agent state.

  ## Example

      agent = AgentProcess.get_agent(pid)
  """
  @spec get_agent(GenServer.server()) :: struct()
  def get_agent(server) do
    GenServer.call(server, :get_agent)
  end

  @doc """
  Returns the agent ID.

  ## Example

      agent_id = AgentProcess.get_id(pid)
      #=> "agent_1"
  """
  @spec get_id(GenServer.server()) :: agent_id()
  def get_id(server) do
    GenServer.call(server, :get_id)
  end

  @doc false
  # The agent id of a local agent process, read from its process dictionary
  # without a call: `{:ok, id}`, or `:error` if the process is gone.
  @spec agent_id_of(pid()) :: {:ok, agent_id()} | :error
  def agent_id_of(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, @agent_id_key, 0) do
          {_key, id} -> {:ok, id}
          nil -> :error
        end

      nil ->
        :error
    end
  end

  @doc """
  Returns agent statistics and metadata.

  ## Example

      stats = AgentProcess.get_stats(pid)
      #=> %{
        agent_id: "agent_1",
        run_count: 42,
        last_run: ~U[2024-01-15 10:30:00Z],
        total_runtime_ms: 15420
      }
  """
  @spec get_stats(GenServer.server()) :: map()
  def get_stats(server) do
    GenServer.call(server, :get_stats)
  end

  @doc """
  Updates the agent config: `update_fn` gets the current
  `%Normandy.Agents.BaseAgentConfig{}` and returns the new one.

  Raises `ArgumentError` when `update_fn` returns anything else; the process keeps its
  config.

  In `:inline` mode the update is queued behind the turn in flight and any runs before it
  (see "Inline turns"), so it sees their memory; the call waits for it.

  ## Options

  #{Options.docs(@update_agent_opts_schema)}

  ## Example

      :ok = AgentProcess.update_agent(pid, fn agent ->
        %{agent | temperature: 0.2}
      end)
  """
  @spec update_agent(
          GenServer.server(),
          (BaseAgentConfig.t() -> BaseAgentConfig.t()),
          timeout: timeout()
        ) :: :ok
  def update_agent(server, update_fn, opts \\ [])

  def update_agent(server, update_fn, opts) when is_function(update_fn, 1) do
    opts = Options.validate!(opts, @update_agent_opts_schema, {__MODULE__, :update_agent, 3})

    case GenServer.call(server, {:update_agent, update_fn}, Keyword.fetch!(opts, :timeout)) do
      :ok ->
        :ok

      {:not_a_config, type} ->
        raise ArgumentError,
              "Normandy.Coordination.AgentProcess.update_agent/2: the function must " <>
                "return a %Normandy.Agents.BaseAgentConfig{}, got: #{type}"
    end
  end

  @doc """
  Stops the agent process gracefully.

  ## Example

      :ok = AgentProcess.stop(pid)
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    agent = Keyword.fetch!(opts, :agent)
    agent_id = Keyword.get_lazy(opts, :agent_id, &UUID.uuid4/0)
    # Readable without a call (see agent_id_of/1), so a busy agent can be listed.
    Process.put(@agent_id_key, agent_id)
    context_pid = Keyword.get(opts, :context_pid)
    turn_engine = Keyword.fetch!(opts, :turn_engine)

    base = %{
      agent: agent,
      agent_id: agent_id,
      context_pid: context_pid,
      turn_engine: turn_engine,
      # :server mode's Turn.Session handle, built once below. update_agent/2 is the only
      # writer of :agent in :server mode, and it refreshes the session's config.
      session: nil,
      owned: [],
      pending_runs: %{},
      # :inline mode: the turn in flight (%{pid, ref, op, started} or nil) and the ops
      # waiting behind it, oldest first (see enqueue/2).
      running: nil,
      queue: :queue.new(),
      run_count: 0,
      last_run: nil,
      total_runtime_ms: 0,
      created_at: DateTime.utc_now()
    }

    case turn_engine do
      :inline ->
        {:ok, base}

      :server ->
        case server_infra(opts) do
          {:ok, store, registry, supervisor, owned} ->
            session =
              Turn.Session.new(
                [
                  session_id: agent_id,
                  config: agent,
                  store: store,
                  registry: registry,
                  supervisor: supervisor
                ] ++ Keyword.take(opts, @session_options)
              )

            {:ok, %{base | session: session, owned: owned}}

          {:error, reason} ->
            {:stop, {:server_init_failed, reason}}
        end
    end
  end

  # Resolve session infra: use what the caller supplied, else start+own defaults.
  # Returns {:ok, store, registry, supervisor, owned_pids} | {:error, reason}.
  defp server_infra(opts) do
    {store, owned_store} =
      case Keyword.get(opts, :store) do
        nil ->
          store_pid = InMemory.new()
          {{Normandy.Behaviours.SessionStore.InMemory, store_pid}, [store_pid]}

        supplied ->
          {supplied, []}
      end

    {registry, owned_reg} =
      case Keyword.get(opts, :registry) do
        nil ->
          name = :"agentprocess_reg_#{System.unique_integer([:positive])}"
          {:ok, reg_pid} = Native.start_link(name: name)
          {{Normandy.Behaviours.SessionRegistry.Native, name}, [reg_pid]}

        supplied ->
          {supplied, []}
      end

    {supervisor, owned_sup} =
      case Keyword.get(opts, :supervisor) do
        nil ->
          {:ok, sup} = Turn.Supervisor.start_link([])
          {sup, [sup]}

        supplied ->
          {supplied, []}
      end

    {:ok, store, registry, supervisor, owned_store ++ owned_reg ++ owned_sup}
  rescue
    e -> {:error, e}
  end

  @impl true
  def terminate(_reason, %{owned: owned}) when is_list(owned) do
    Enum.each(owned, fn pid ->
      if is_pid(pid) and Process.alive?(pid) do
        # Unlink BEFORE killing: these owned infra pids are linked to us (started
        # via start_link in server_infra/1). Without the unlink, their `:shutdown`
        # death bounces back through the link and re-exits this process with
        # `:shutdown` (we don't trap exits) — which then propagates to whoever
        # `start_link`ed US (e.g. a caller that just invoked `stop/1`), killing it.
        Process.unlink(pid)
        Process.exit(pid, :shutdown)
      end
    end)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:run, input}, from, state), do: handle_call({:run, input, nil}, from, state)

  # The caller's OTel context rides in the call so the run nests under the
  # caller's span. The two-element shape (no context) is still accepted.
  def handle_call({:run, input, otel_ctx}, from, %{turn_engine: :server} = state) do
    start_time = System.monotonic_time(:millisecond)
    ref = spawn_run(state, prepare_input(input), otel_ctx)
    {:noreply, %{state | pending_runs: Map.put(state.pending_runs, ref, {from, start_time})}}
  end

  # :inline: queued behind the turn in flight; the reply comes from handle_info/2.
  @impl true
  def handle_call({:run, input, otel_ctx}, from, state) do
    {:noreply, enqueue({:run, from, input, otel_ctx}, state)}
  end

  @impl true
  def handle_call(:get_agent, _from, %{turn_engine: :server} = state) do
    {:reply, reconstruct_agent(state), state}
  end

  @impl true
  def handle_call(:get_agent, _from, state) do
    {:reply, state.agent, state}
  end

  @impl true
  def handle_call(:get_id, _from, state) do
    {:reply, state.agent_id, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      agent_id: state.agent_id,
      run_count: state.run_count,
      last_run: state.last_run,
      total_runtime_ms: state.total_runtime_ms,
      created_at: state.created_at
    }

    {:reply, stats, state}
  end

  # A result that is not a config is refused here, before it replaces the agent: the
  # caller raises (update_agent/2), the process keeps running with its config. The
  # reply names only its type (a config holds the client and its credentials).
  # :inline: queued like a run, so it sees the memory of every run before it and no run
  # in flight overwrites it.
  @impl true
  def handle_call({:update_agent, update_fn}, from, %{turn_engine: :inline} = state) do
    {:noreply, enqueue({:update, from, update_fn}, state)}
  end

  def handle_call({:update_agent, update_fn}, _from, state) do
    {reply, state} = update_agent_now(update_fn, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:approve, decisions}, _from, %{turn_engine: :server} = state) do
    {:reply, Turn.Session.approve(state.session, decisions), state}
  end

  @impl true
  def handle_call({:approve, _decisions}, _from, state) do
    {:reply, {:error, :inline_mode}, state}
  end

  # update_agent/2's new config. In :server mode the SessionStore owns the memory, so
  # a changed memory is ignored; the session's next server start uses the new config.
  defp update_agent_now(update_fn, state) do
    case update_fn.(state.agent) do
      %BaseAgentConfig{} = updated -> {:ok, put_agent(updated, state)}
      other -> {{:not_a_config, Describe.type_of(other)}, state}
    end
  end

  defp put_agent(updated, %{turn_engine: :server} = state) do
    new_agent =
      if updated.memory != state.agent.memory do
        Logger.warning(
          "AgentProcess #{state.agent_id}: update_agent memory mutation ignored in :server mode " <>
            "(SessionStore is authoritative)"
        )

        %{updated | memory: state.agent.memory}
      else
        updated
      end

    %{state | agent: new_agent, session: Turn.Session.put_config(state.session, new_agent)}
  end

  defp put_agent(updated, state), do: %{state | agent: updated}

  @impl true
  def handle_cast({:run_async, input, reply_to}, state),
    do: handle_cast({:run_async, input, reply_to, nil}, state)

  def handle_cast({:run_async, input, reply_to, otel_ctx}, %{turn_engine: :server} = state) do
    session = state.session
    agent_id = state.agent_id
    user_input = prepare_input(input)

    _ =
      Task.start(fn ->
        OtelCtx.restore(otel_ctx)
        # Guarantee reply_to always hears back with {:error, exception}, the same one
        # run/3 replies when its worker dies of the same failure (the :DOWN clause): a
        # domain exception bare, any other raise, exit or throw a :task_down TurnError.
        # Stacktraces are logged (arities only), never replied.
        result =
          try do
            case Turn.Session.run(session, user_input) do
              {:ok, value} -> {:ok, extract_result(value)}
              {:error, _} = err -> err
            end
          catch
            kind, reason ->
              Logger.error(
                "Async agent #{agent_id} raised " <>
                  TurnError.format_raised(kind, reason, __STACKTRACE__)
              )

              {:error, TurnError.from_reason({:task_down, exit_reason(kind, reason)})}
          end

        if reply_to, do: send(reply_to, {:agent_result, agent_id, result})
      end)

    {:noreply, %{state | run_count: state.run_count + 1, last_run: DateTime.utc_now()}}
  end

  @impl true
  def handle_cast({:run_async, input, reply_to, otel_ctx}, state) do
    # Spawn task to run agent without blocking GenServer
    {:ok, _task_pid} =
      Task.start(fn ->
        OtelCtx.restore(otel_ctx)
        result = handle_async_run(state.agent, input, state.agent_id)

        if reply_to do
          send(reply_to, {:agent_result, state.agent_id, result})
        end
      end)

    # Update run count
    updated_state = %{
      state
      | run_count: state.run_count + 1,
        last_run: DateTime.utc_now()
    }

    {:noreply, updated_state}
  end

  # Spawn a monitored, UNLINKED worker that runs the turn and tags its reply
  # with the monitor ref (so {:run_result, ref, …} and {:DOWN, ref, …} correlate).
  defp spawn_run(state, user_input, otel_ctx) do
    server = self()
    session = state.session

    worker =
      spawn(fn ->
        OtelCtx.restore(otel_ctx)

        ref =
          receive do
            {:monitor_ref, r} -> r
          end

        result =
          case Turn.Session.run(session, user_input) do
            {:ok, value} -> {:ok, extract_result(value)}
            {:error, _} = err -> err
          end

        send(server, {:run_result, ref, result})
      end)

    ref = Process.monitor(worker)
    send(worker, {:monitor_ref, ref})
    ref
  end

  # :inline: the turn in flight finished (or its worker died); start the next op.
  @impl true
  def handle_info({:inline_result, pid, result}, %{running: %{pid: pid} = running} = state) do
    Process.demonitor(running.ref, [:flush])
    {:noreply, state |> finish_op(running, result) |> dispatch()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref} = running} = state) do
    error = {:error, TurnError.from_reason({:task_down, reason})}
    {:noreply, state |> finish_op(running, error) |> dispatch()}
  end

  def handle_info({:run_result, ref, result}, state) do
    case Map.pop(state.pending_runs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, start_time}, rest} ->
        Process.demonitor(ref, [:flush])
        runtime = System.monotonic_time(:millisecond) - start_time
        GenServer.reply(from, result)

        {:noreply,
         %{
           state
           | pending_runs: rest,
             run_count: state.run_count + 1,
             last_run: DateTime.utc_now(),
             total_runtime_ms: state.total_runtime_ms + runtime
         }}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending_runs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, _start}, rest} ->
        GenServer.reply(from, {:error, TurnError.from_reason({:task_down, reason})})
        {:noreply, %{state | pending_runs: rest}}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("AgentProcess #{state.agent_id} ignoring unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  # :inline ops run one at a time, oldest first: {:run, from, input, otel_ctx} and
  # {:update, from, update_fn}.
  defp enqueue(op, state), do: dispatch(%{state | queue: :queue.in(op, state.queue)})

  # Starts queued ops while no turn is in flight: an update applies at once, a run
  # starts a worker (and dispatching stops until it finishes).
  defp dispatch(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} -> state
      {{:value, op}, queue} -> dispatch(start_op(op, %{state | queue: queue}))
    end
  end

  defp dispatch(state), do: state

  defp start_op({:update, from, update_fn}, state) do
    {reply, state} = update_agent_now(update_fn, state)
    GenServer.reply(from, reply)
    state
  end

  defp start_op({:run, from, input, otel_ctx} = op, state) do
    if caller_alive?(from),
      do: start_turn(op, "Agent #{state.agent_id}", input, otel_ctx, state),
      else: state
  end

  # The worker gets the committed config, the input and the caller's OTel context, not
  # the process state.
  defp start_turn(op, who, input, otel_ctx, state) do
    agent = state.agent

    {pid, ref} =
      WatchedWorker.start(:inline_result, fn ->
        OtelCtx.restore(otel_ctx)
        inline_turn(agent, input, who)
      end)

    running = %{pid: pid, ref: ref, op: op, started: System.monotonic_time(:millisecond)}
    %{state | running: running}
  end

  defp finish_op(state, %{op: {:run, from, _input, _ctx}} = running, result) do
    state = %{state | running: nil}

    case result do
      {:ok, agent, value} ->
        GenServer.reply(from, {:ok, value})
        count_run(%{state | agent: agent}, running.started)

      {:error, _exception} = error ->
        GenServer.reply(from, error)
        state
    end
  end

  defp count_run(state, started) do
    %{
      state
      | run_count: state.run_count + 1,
        last_run: DateTime.utc_now(),
        total_runtime_ms: state.total_runtime_ms + System.monotonic_time(:millisecond) - started
    }
  end

  # A caller that died while its run waited (a Reactive task killed past its timeout)
  # gets no turn. Only a local pid can be checked; a remote caller's run always starts.
  defp caller_alive?({pid, _tag}) when node(pid) == node(), do: Process.alive?(pid)
  defp caller_alive?(_from), do: true

  # One inline turn, in the worker. A Normandy error is returned; a raise (a bug) is
  # logged (arities only) and returned bare; an exit or a throw is logged and becomes
  # the :task_down TurnError a worker dying of it would give.
  defp inline_turn(agent, input, who) do
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, updated_agent, response} -> {:ok, updated_agent, extract_result(response)}
      {:error, exception} -> {:error, exception}
    end
  rescue
    e -> TurnError.log_raised(who, e, __STACKTRACE__)
  catch
    kind, reason when kind in [:exit, :throw] ->
      Logger.error("#{who} raised " <> TurnError.format_raised(kind, reason, __STACKTRACE__))
      {:error, TurnError.from_reason({:task_down, exit_reason(kind, reason)})}
  end

  # The exit reason a process dies with for a caught kind and reason, so a failure caught
  # in run_async maps like the same failure arriving as run/3's worker :DOWN.
  defp exit_reason(:error, reason), do: Exception.normalize(:error, reason)
  defp exit_reason(:throw, value), do: {:nocatch, value}
  defp exit_reason(:exit, reason), do: reason

  defp prepare_input(input) when is_map(input) and not is_struct(input) do
    Map.get(input, :chat_message) || Map.get(input, "chat_message") || input
  end

  defp prepare_input(input) when is_binary(input) do
    %{chat_message: input}
  end

  defp prepare_input(input), do: input

  defp extract_result(response) when is_map(response) do
    Map.get(response, :chat_message) ||
      Map.get(response, "chat_message") ||
      response
  end

  defp handle_async_run(agent, input, agent_id) do
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, _updated_agent, response} -> {:ok, extract_result(response)}
      {:error, exception} -> {:error, exception}
    end
  rescue
    e -> TurnError.log_raised("Async agent #{agent_id}", e, __STACKTRACE__)
  end

  # Store-authoritative read: rebuild config.memory from the SessionStore so callers
  # see durable truth. On a store fault, log and return the template unchanged.
  defp reconstruct_agent(%{
         session: %Turn.Session{store: {mod, handle}},
         agent: agent,
         agent_id: sid
       }) do
    case mod.history(handle, sid) do
      {:ok, entries} ->
        rebuilt = %{
          AgentMemory.from_entries(entries)
          | max_messages: agent.memory.max_messages
        }

        %{agent | memory: rebuilt}

      {:error, reason} ->
        Logger.warning(
          "AgentProcess #{sid}: get_agent could not read store: #{Describe.reason_tag(reason)}"
        )

        agent
    end
  end
end
