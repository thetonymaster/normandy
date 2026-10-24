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
  the previous one left, so a cast's turn is kept in memory like a run's. The process
  itself never waits on a turn: `get_agent/1` (the config as of the last finished turn),
  `get_id/1`, `get_stats/1` and `approve/2` answer at once while a turn runs. A run whose
  caller died while it waited in the queue is skipped. The worker dies with the process
  (`stop/1` kills a turn in flight); a worker killed from outside replies a `:task_down`
  `Normandy.TurnError`.

  ## Pending runs

  Runs and casts that were admitted and have not finished (queued or in flight, in
  either mode) are bounded by `:max_pending_runs` (default 100). One more is refused at
  once: `run/3` returns, and `cast/3` sends to `:reply_to`,
  `{:error, %Normandy.TurnError{type: :queue_full, reason: limit}}`. `get_stats/1`'s
  `run_count` counts runs and casts that finished, failed ones included.

  ## Durable turn engine (`:server` mode)

  Pass `turn_engine: :server` to route turns through the durable
  `Normandy.Agents.Turn.Session`/`Turn.Server` engine (approval parking,
  passivation, persistence) instead of the default `:inline` path, which runs
  `BaseAgent.run/3` in a worker process, one turn at a time. `:inline` is the default and is unchanged.

      {:ok, pid} = AgentProcess.start_link(agent: config, turn_engine: :server)

  In `:server` mode:

  - `run/3`/`cast/3` route through `Turn.Session`; `run/3` is non-blocking
    internally (the GenServer stays responsive while a turn is parked);
    `approve/2` delivers human-approval decisions to a parked turn.
  - The `SessionStore` owns conversation memory: `get_agent/1` reconstructs it
    from the store, and `update_agent/2` updates only the config template
    (model/temperature/behaviours/tools) — memory mutations are ignored.
  - Session infra (`:store`, `:registry`, `:supervisor`) may be supplied via
    `start_link`; if omitted, the process starts and owns an in-memory store and a
    `Turn.Supervisor` that terminate with it, and registers its sessions under a scope
    of its own in a registry Normandy starts (no atom per process). `start_link` builds
    one `Turn.Session` from them and from
    `:supervisor_mod`, `:template_provider`, `:template_id`, `:resume_policy`,
    `:subscriber`, `:handlers`, `:approval_timeout_ms`, `:on_approval_timeout` and
    `:idle_timeout_ms` (see `Turn.Session.new/1`; `start_link/1` checks them with its types);
    `update_agent/2` gives it the new config for the next server start.
  """

  use GenServer
  require Logger

  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Turn
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Coordination.AgentProcess.Engine
  alias Normandy.Options
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.TurnError

  @agent_id_key :"$normandy_agent_id"

  # The :server-mode keys go to Turn.Session.new/1 (Engine.Server.init/3); its schema is the
  # single source of their types (ruling P4), so a value accepted here cannot fail there and
  # crash init/1. Types only: Session's required/default flags do not apply.
  @session_types Map.new(Turn.Session.__opts_schema__(:new).schema, fn {key, spec} ->
                   {key, Keyword.fetch!(spec, :type)}
                 end)

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
                                "`:inline` runs `BaseAgent.run/3` in a worker process, one turn at a time; `:server` " <>
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
                                  "Without it the process uses a scope of its own in a " <>
                                  "registry Normandy starts."
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
                            ],
                            max_pending_runs: [
                              type: {:or, [:pos_integer, {:in, [:infinity]}]},
                              default: 100,
                              type_doc: "a positive integer or `:infinity`",
                              doc:
                                "Runs and casts admitted and not finished (queued or in " <>
                                  "flight). One more is refused with a `:queue_full` " <>
                                  "`Normandy.TurnError`."
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

  Raises `ArgumentError` when `update_fn` returns anything else, and in `:server` mode
  when the session refuses the new config (`Normandy.Agents.Turn.Session.put_config/2`:
  a session with a `:template_provider` needs a `credential` provider); the process keeps
  its config.

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
              "Normandy.Coordination.AgentProcess.update_agent/3: the function must " <>
                "return a %Normandy.Agents.BaseAgentConfig{}, got: #{type}"

      # The :server session refused the new config (Turn.Session.put_config/2).
      {:error, %ArgumentError{} = exception} ->
        raise exception
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
    turn_engine = Keyword.fetch!(opts, :turn_engine)
    engine = Engine.module(turn_engine)

    case engine.init(opts, agent, agent_id) do
      {:ok, engine_state, owned} ->
        {:ok,
         %{
           agent: agent,
           agent_id: agent_id,
           context_pid: Keyword.get(opts, :context_pid),
           turn_engine: turn_engine,
           engine: engine,
           engine_state: engine_state,
           # Infra pids the engine started; stopped with this process.
           owned: owned,
           run_count: 0,
           last_run: nil,
           total_runtime_ms: 0,
           created_at: DateTime.utc_now(),
           max_pending_runs: Keyword.fetch!(opts, :max_pending_runs),
           # Runs and casts admitted and not finished (see admit/2).
           pending: 0
         }}

      {:error, reason} ->
        {:stop, {:server_init_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{owned: owned}) when is_list(owned) do
    Enum.each(owned, fn pid ->
      if is_pid(pid) and Process.alive?(pid) do
        # Unlink BEFORE killing: these owned infra pids are linked to us (started
        # via start_link in Engine.Server.init/3). Without the unlink, their `:shutdown`
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

  # What a crash report, :sys.get_status/1 and the observer show of this process: its
  # id, engine and counters, never the agent (its memory, its client's credentials) nor
  # the input of a queued run, cast or update (decision 6, as Turn.Server). The last
  # message is reduced to its request tag, the sys debug log to its length, and a
  # crash's reason as Turn.Server reduces it. format_status/1 is OTP 25+; OTP 24 calls
  # format_status/2.
  if String.to_integer(List.to_string(:erlang.system_info(:otp_release))) >= 25 do
    @impl true
    def format_status(status) do
      status
      |> Map.update(:state, nil, &status_state/1)
      |> Map.update(:message, nil, &message_tag/1)
      |> Map.update(:reason, nil, &(&1 |> TurnError.drop_stacktraces() |> TurnError.redact()))
      |> Map.update(:log, [], &length/1)
    end
  else
    @impl true
    def format_status(_opt, [_pdict, state]),
      do: [data: [{~c"State", status_state(state)}]]
  end

  defp status_state(%{agent_id: _} = state) do
    %{queued: queued, in_flight: in_flight} = state.engine.load(state)

    %{
      agent_id: state.agent_id,
      turn_engine: state.turn_engine,
      pending: state.pending,
      run_count: state.run_count,
      queued: queued,
      in_flight: in_flight
    }
  end

  defp status_state(_other), do: :redacted

  defp message_tag({:"$gen_call", _from, request}), do: {:"$gen_call", request_tag(request)}
  defp message_tag({:"$gen_cast", request}), do: {:"$gen_cast", request_tag(request)}
  defp message_tag(message), do: request_tag(message)

  defp request_tag(request) when is_atom(request), do: request

  defp request_tag(request)
       when is_tuple(request) and tuple_size(request) > 0 and is_atom(elem(request, 0)),
       do: elem(request, 0)

  defp request_tag(request), do: Describe.type_of(request)

  @impl true
  def handle_call({:run, input}, from, state), do: handle_call({:run, input, nil}, from, state)

  # The caller's OTel context rides in the call so the run nests under the
  # caller's span. The two-element shape (no context) is still accepted.
  def handle_call({:run, input, otel_ctx}, from, state) do
    case admit({:run, from, input, otel_ctx}, state) do
      {:ok, state} -> {:noreply, state}
      {:error, _} = full -> {:reply, full, state}
    end
  end

  @impl true
  def handle_call(:get_agent, _from, state) do
    {:reply, state.engine.get_agent(state), state}
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

  # A result that is not a config is refused by the engine, before it replaces the agent:
  # the caller raises (update_agent/2), the process keeps running with its config.
  @impl true
  def handle_call({:update_agent, update_fn}, from, state),
    do: state.engine.update_agent(update_fn, from, state)

  @impl true
  def handle_call({:approve, decisions}, _from, state) do
    {:reply, state.engine.approve(decisions, state), state}
  end

  @impl true
  def handle_cast({:run_async, input, reply_to}, state),
    do: handle_cast({:run_async, input, reply_to, nil}, state)

  def handle_cast({:run_async, input, reply_to, otel_ctx}, state) do
    case admit({:cast, reply_to, input, otel_ctx}, state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, _} = full ->
        Engine.notify(reply_to, state.agent_id, full)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    case state.engine.handle_info(msg, state) do
      {:noreply, _state} = reply ->
        reply

      :unhandled ->
        Logger.debug(
          "AgentProcess #{state.agent_id} ignoring unexpected message: #{inspect(msg)}"
        )

        {:noreply, state}
    end
  end

  # Private Functions

  # A run ({:run, from, input, otel_ctx}) or cast ({:cast, reply_to, input, otel_ctx}) is
  # admitted while fewer than :max_pending_runs are pending; the engine starts it at once
  # (:server, where Turn.Server serializes the turns) or queues it (:inline).
  defp admit(_op, %{max_pending_runs: max, pending: pending})
       when max != :infinity and pending >= max,
       do: {:error, TurnError.from_reason({:queue_full, max})}

  defp admit(op, state), do: {:ok, state.engine.admit(op, %{state | pending: state.pending + 1})}
end
