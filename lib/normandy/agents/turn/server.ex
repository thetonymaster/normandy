defmodule Normandy.Agents.Turn.Server do
  @moduledoc """
  Asynchronous `:gen_statem` interpreter of the pure `Turn` FSM — the async analog
  of `Turn.Driver`. Coarse lifecycle states (`:running`, `:awaiting_approval`,
  `:idle`) hang Tasks and `state_timeout`s off the turn; they are NOT a
  re-encoding of the seven `Turn.State` statuses (the core stays the source of
  truth). Blocking effects (`:call_llm`, `:dispatch_tools`, `:execute_approved`)
  run in a monitored Task; non-blocking effects run synchronously in the handler.

  ## Options

  See `start_link/1`. Approval expiry emits `[:normandy, :turn, :approval, :expired]` for the
  batch and a `[:normandy, :tool, :denied]` (reason `:approval_expired`) per call; a rejected
  call emits `[:normandy, :tool, :denied]` with `:approval_rejected`.

  Each park is wrapped in a `[:normandy, :turn, :approval, :start | :stop]` span
  (hand-emitted; both events carry the same `:telemetry_span_context`). `:start`
  metadata: `session_id`, `tool_names`, `count` and the run's ids (`turn_id`,
  `conversation_id`). `:stop` adds `outcome` (`:approved`,
  `:rejected`, `:mixed`, `:expired`, or `:terminated` when the server stops while
  parked) and measures `duration`. The run span stays one span across parks; its
  `:stop`/`:exception` measurements add `approval_wait` (native units, the sum of all
  parks in the turn, 0 if never parked). `BaseAgent.run/2` never parks, so its run
  events carry no `approval_wait`. A turn resumed after a restart that lands in
  `:awaiting_approval` opens a fresh approval span (the old one died with the old
  process) inside the resumed run's span. `Normandy.Telemetry` catalogues every event.

  A Tier-2 `Turn.Session` saves `:approval_timeout_ms`, `:on_approval_timeout` and
  `:idle_timeout_ms` with the config template. A thin start (no `:config`) restores
  them; explicit start options still win. `:handlers` and `:subscriber` are
  functions and are never saved, so whoever restarts the server passes them (see
  `ResumeReaper`).

  ## Store unavailable

  Every start, supervisor restarts included, loads the session from the store. If
  the store fails that load, or the load raises, exits or throws (a template or
  credential provider, the template's rebuild), the start still succeeds: the server
  waits in `:unavailable`, retries the load on a backoff timer (200 ms doubling to 30 s)
  and on every `run/2`, and replies `{:error, %Normandy.TurnError{type:
  :session_unavailable, reason: reason}}` until a load succeeds. `reason` is the store's
  reason reduced to its tags (atoms and integers kept, an exception as its module, any
  other term as its type: `{:query_failed, "a map"}`), `{:store_exit, exit_reason}` for a
  store call that exited, or the exception the load raised. It then carries on as
  a normal start would, eager resume included. An approval that arrives while the load
  fails is dropped with a warning. With no call for `:idle_timeout_ms`, the server stops
  normally.

  A hook list this node cannot run (`{:invalid_hooks, message}`: a hook module missing
  on this node, or invalid hook opts) is handled the same way: the server waits
  `:unavailable`, retries, and replies that reason in a `:session_unavailable` `TurnError`.
  So is a stored template that `Normandy.Agents.ConfigTemplate.check_loaded!/1` refuses,
  or whose security settings differ from the supplement's `:pinned`
  (`{:invalid_template, message}`): nothing in it is used, and its credential provider is
  not called.

  ## Session start

  A session whose store holds no entries and no turn state is new. Its
  `on_session_start` hooks (`Normandy.Behaviours.Hooks`) run as the first event after
  `init/1` returns, so the supervisor starting the server is not blocked by them. What
  they inject is stored as one user message. A hook crash or a store fault writing that
  message sends the server `:unavailable`, which retries both like a load; meanwhile
  `run/2` replies a `:session_unavailable` `TurnError` whose `:reason` is the
  `:handler_crashed` (handler `:on_session_start`) or `:persist_failed` `TurnError`. A session
  whose hooks injected nothing is still new on its next start, and runs them again.

  ## Events (`:subscriber`)

    * `:iteration` — `%{iteration: n, iterations_left: m, final: boolean}` before each
      LLM call; `final: true` marks the last call, made with `tool_choice: :none` after the budget is spent.
    * `:steering` — `%{iterations_left: m}` after a tool batch, once its state is saved.
    * `:awaiting_approval` — `%{parked: n, resumed: boolean}` when a batch parks, and
      again (`resumed: true`) when a restarted server resumes a parked turn.
    * `:approval_expired` — `%{expired: n, mode: :continue | :fail}`.

  ## Telemetry

  Each turn started by `run/2` emits `[:normandy, :agent, :run, :start]`, then
  `:stop` or `:exception` (`kind: :error`, `reason`: the exception `run/2` replies,
  `stacktrace: []`), with `model`, `agent_name` and `session_id` metadata, like
  `BaseAgent.run/2`. A rejected input emits a `:start` and an `:exception` too.

  A turn that a restarted server resumes (eager resume) emits a run `:start` of its
  own with `resumed: true` in the metadata, and later `:stop` or `:exception`; its
  `approval_wait` counts only the parks after the restart. The OpenTelemetry context
  of the original `run/2` caller is saved with the turn state as a W3C text-map
  carrier (`Turn.State.trace_carrier`), and the resumed run's `:start` fires with
  that context current, so a bridged run span becomes a child of the original
  caller's span, in its trace. Parenting is the only relation a telemetry bridge can
  express (it reads the current context); a span link would need bridge support. The
  original run span is not the parent: it ends when the old server stops, or is
  never exported when the old server was killed, while the caller's span is.

  `approve/2` carries the approver's OpenTelemetry context. It is current while the
  approval `:stop` and the `[:normandy, :tool, :denied]` events of rejected calls
  fire, so a handler can correlate them with the approver's trace; the run keeps its
  own context.

  A server that stops with a turn in flight, through a callback-initiated stop or
  `:gen_statem.stop/3`, emits `:exception` with `kind: :exit` and the stop reason in
  `terminate/3`. The server does not trap exits, so an exit signal that kills it
  (`:kill`, a supervisor's `Process.exit/2`, a linked process dying) runs no callback
  and emits no `:exception`. Stray messages are logged at debug and dropped.

  ## Errors from `run/2`

  `run/2` returns `{:error, exception}`, never a tagged tuple or a stacktrace.
  Normandy's own exceptions are replied bare:

    * `Normandy.LLMError` - the LLM call failed (a 429 after the tools ran included).
    * `Normandy.Schema.ValidationError` - the input failed its schema.
    * `Normandy.Guardrails.ViolationError` - an input guardrail blocked the input, or an
      output guardrail blocked the answer.
    * `Normandy.HookHaltError` - an `on_prompt` hook (`event: :on_prompt`) or a
      `before_llm` hook (`event: :before_llm`) halted the turn.
    * `Normandy.ModelCatalogError` - compaction could not look up the model's context
      window.

  Anything else is a `Normandy.TurnError`, whose `:type` says what failed:

    * `:handler_crashed` - a handler or hook raised, exited or threw; `:handler` names it:
      a synchronous handler (`:append`, `:convert`, `:validate`, `:guard`, `:emit`),
      admission (`:admit`: an `on_prompt` hook or an input guardrail crashing under
      `on_error: :reraise`, or a hook's return-contract violation), an `after_tool` hook
      on a result the server built itself (an approval rejected, expired or interrupted
      result), or a `before_llm` or `after_compact` hook.
    * `:persist_failed` - the session store rejected a write; `:reason` is its reason, or
      `{:store_exit, exit_reason}` when the store call exited. The write is not adopted
      and the server stays up; a store that raises is a bug and crashes the server.
    * `:approval_timeout` - nobody approved in time and `on_approval_timeout: :fail`;
      `:reason` is the list of tool call ids.
    * `:task_down` - the LLM call, the compactor or the tool dispatch raised an
      exception that is not one of the above (a `before_tool` or `after_tool` hook
      crashing inside the dispatch under `on_error: :reraise` included), or its worker
      exited or threw; `:reason` is the exception or the exit reason.
    * `:session_unavailable` - the session could not be loaded or started (see "Store
      unavailable" and "Session start"); `:reason` is that failure.
    * `:unexpected_event`, `:unresumable_state` - a persisted turn that can't continue,
      or a Normandy bug.

  A rejected input or a blocked answer persists nothing of the answer (the user message
  is kept for a blocked answer); the server stays alive in every case. `on_turn_end`
  hooks receive `{:rejected, exception}` for a rejection and `{:error, exception}`,
  the replied exception, for every other failure.

  ## Interrupted tool calls

  A turn that fails or is killed after the assistant's `tool_use` was appended leaves
  it unanswered. The next turn whose input is admitted (a rejected input repairs
  nothing) appends an `interrupted: true` tool result for each missing call, in memory
  and store, before the user message, and logs a warning.
  Each interrupted result passes the hook modules' `after_tool` once
  (`Normandy.Behaviours.Hooks`); so do the results the core builds for approval
  rejections and expiries.
  If a store write fails part-way, memory keeps only the results the store accepted,
  so the next turn completes the repair without duplicating any result. The same
  holds for tool results written during a turn: a rejected write is not adopted into
  memory. A crash in the `:emit` handler while re-announcing a resumed parked turn
  fails that turn (no caller is waiting), and the next turn closes its batch with
  interrupted results. An eagerly resumed `:steering` turn closes the batch the same
  way before its next LLM call; a resumed parked turn is left alone, since its
  unanswered calls await a decision.
  """
  @behaviour :gen_statem

  alias Normandy.Agents.{BaseAgent, Dispatch, Turn}
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Components.ToolCall
  alias Normandy.Hooks.Runner
  alias Normandy.Hooks.ServerGlue
  alias Normandy.Options
  alias Normandy.Telemetry.Metadata
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.Telemetry.Span
  alias Normandy.TurnError

  require Logger

  defmodule Data do
    @moduledoc false
    defstruct turn_state: nil,
              config: nil,
              session_id: nil,
              store: nil,
              registry: nil,
              subscriber: nil,
              handlers: nil,
              task_ref: nil,
              task_kind: nil,
              pending_reply: nil,
              approval_timeout_ms: 300_000,
              on_approval_timeout: :continue,
              idle_timeout_ms: 60_000,
              template_provider: nil,
              resume_policy: :lazy,
              run_span: nil,
              approval_span: nil,
              approval_wait: 0,
              start_opts: nil,
              retry_ms: nil
  end

  # A turn request: {:turn, input, caller_otel_ctx}. The two-element {:turn, input}
  # sent by a caller running an older Normandy (another node during a rolling
  # deploy) is still accepted, with no caller context.
  defguardp is_turn_request(msg)
            when is_tuple(msg) and tuple_size(msg) in [2, 3] and elem(msg, 0) == :turn

  # Backoff between load retries while the store is unavailable.
  @retry_initial_ms 200
  @retry_max_ms 30_000

  # ---- public API ----

  # Turn.Session.new/1's schema is the single source of the types of the keys a session
  # passes on (ruling P4): a value one accepts, the other accepts too.
  @session_types Map.new(Normandy.Agents.Turn.Session.__opts_schema__(:new).schema, fn {key, spec} ->
                   {key, Keyword.fetch!(spec, :type)}
                 end)

  @start_link_opts_schema NimbleOptions.new!(
                            session_id: [
                              type: @session_types.session_id,
                              required: true,
                              doc: "The session this server runs."
                            ],
                            store: [
                              type: @session_types.store,
                              required: true,
                              doc: "The `Normandy.Behaviours.SessionStore` as `{module, handle}`."
                            ],
                            registry: [
                              type: @session_types.registry,
                              required: true,
                              doc:
                                "The `Normandy.Behaviours.SessionRegistry` as `{module, handle}`. " <>
                                  "The server registers itself under `:session_id` unless it " <>
                                  "was started under a `:via` name."
                            ],
                            config: [
                              type: {:struct, Normandy.Agents.BaseAgentConfig},
                              type_doc: "a `%Normandy.Agents.BaseAgentConfig{}`",
                              doc:
                                "The agent config. Without it the server rebuilds the config " <>
                                  "from the template saved in `:store` (a thin start), which " <>
                                  "needs `:template_provider`."
                            ],
                            template_provider: [
                              type: @session_types.template_provider,
                              type_doc: "`{module, handle}`",
                              doc:
                                "The `Normandy.Behaviours.AgentTemplate` as `{module, handle}`, " <>
                                  "for a thin start."
                            ],
                            resume_policy: [
                              type: @session_types.resume_policy,
                              doc:
                                "`:lazy` (the default) or `:eager`: `:eager` resumes an " <>
                                  "in-flight turn as soon as the server starts. A saved " <>
                                  "template's value wins over this option."
                            ],
                            subscriber: [
                              type: {:or, [{:fun, 2}, nil]},
                              doc:
                                "`fn event_name, meta -> any end`, called in the server process " <>
                                  "for every event. A crash in it is logged, reported as " <>
                                  "`[:normandy, :turn, :subscriber, :exception]` telemetry, " <>
                                  "and ignored. Never saved with the template."
                            ],
                            handlers: [
                              type: @session_types.handlers,
                              type_doc: "a `Normandy.Agents.Turn.Driver.Handlers` or `nil`",
                              doc:
                                "A `Normandy.Agents.Turn.Driver.Handlers` set (default " <>
                                  "`Normandy.Agents.BaseAgent`'s non-streaming handlers). A `nil` " <>
                                  "`:emit` is skipped. Hook modules' `before_llm` and " <>
                                  "`after_compact` run around whichever set is used. Never saved " <>
                                  "with the template."
                            ],
                            approval_timeout_ms: [
                              type: @session_types.approval_timeout_ms,
                              doc:
                                "How long a parked turn waits for `approve/2`, in ms (default " <>
                                  "300_000). Wins over a saved template's value."
                            ],
                            on_approval_timeout: [
                              type: @session_types.on_approval_timeout,
                              doc:
                                "`:continue` (the default) or `:fail`. On expiry every parked " <>
                                  "call gets an `expired: true` tool result; `:continue` hands it " <>
                                  "to the model, `:fail` ends the turn with `{:error, " <>
                                  "%Normandy.TurnError{type: :approval_timeout}}`. Wins over a " <>
                                  "saved template's value."
                            ],
                            idle_timeout_ms: [
                              type: @session_types.idle_timeout_ms,
                              doc:
                                "Idle time before passivation, in ms (default 60_000). Wins " <>
                                  "over a saved template's value."
                            ],
                            name: [
                              type: :any,
                              doc:
                                "A `:gen_statem` server name. `Turn.Supervisor.start_server/2` " <>
                                  "sets it from the registry's `child_name/2` and rejects one " <>
                                  "passed to it."
                            ]
                          )

  @doc false
  def __opts_schema__(:start_link), do: @start_link_opts_schema

  @doc """
  Starts a session server. Options are checked here, in the caller, so a bad option raises
  `ArgumentError` instead of failing `init/1`.

  ## Options

  #{Options.docs(@start_link_opts_schema)}
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end

  @doc """
  Run a turn synchronously; replies once the turn finalizes or fails, with
  `{:ok, response}` or `{:error, exception}` (see "Errors from `run/2`").

  The caller's OpenTelemetry context travels with the request, so the turn's run
  span nests under the caller's active span (a no-op without OTel).
  """
  @spec run(:gen_statem.server_ref(), term()) :: {:ok, term()} | {:error, Exception.t()}
  def run(server, user_input),
    do: :gen_statem.call(server, {:turn, user_input, OtelCtx.capture()}, :infinity)

  @doc """
  Deliver approval decisions to a parked server.

  The caller's OpenTelemetry context travels with the decisions; see "Telemetry".
  """
  @spec approve(:gen_statem.server_ref(), %{optional(String.t()) => :approve | :reject}) :: :ok
  def approve(server, decisions),
    do: :gen_statem.cast(server, {:approval, decisions, OtelCtx.capture()})

  # ---- :gen_statem callbacks ----

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    check_start_source!(opts, session_id)

    register_self(%Data{registry: Keyword.fetch!(opts, :registry), session_id: session_id})

    # The store is the only source of durable state, on a first start and on a
    # supervisor restart alike: the start arguments are captured once and would
    # bring back the memory and turn state of the first start. Starting without
    # the saved turn would drop it, and failing the start would make the
    # supervisor retry at once, spending the restart limit every session shares.
    # So a store fault starts the server :unavailable, retrying the load.
    case safe_load(opts) do
      {:ok, config, template, turn_state} ->
        opts |> init_data(config, template, turn_state) |> with_session_start()

      {:error, reason} ->
        unavailable(opts, reason)
    end
  end

  # No :config AND no :template_provider: a Tier-2 thin start can't reconstruct. A
  # misconfigured start, not a load fault, so it fails the start before any IO.
  defp check_start_source!(opts, session_id) do
    unless Keyword.has_key?(opts, :config) or Keyword.has_key?(opts, :template_provider) do
      raise ArgumentError,
            "Turn.Server: session #{inspect(session_id)} was started with neither :config " <>
              "nor :template_provider. A Tier-2 (Horde) thin start requires :template_provider " <>
              "so the server can reconstruct config from the persisted template."
    end
  end

  # The whole load (store reads, the template and credential providers, the template's
  # rebuild, the hook check) runs here. Anything it raises, exits or throws is logged by
  # its type and becomes {:load_crashed, exception}: the server waits :unavailable and
  # retries, instead of crashing into a supervisor restart (the restarted server would
  # crash the same way, spending the restart limit every session shares).
  defp safe_load(opts) do
    load_session(opts, Keyword.fetch!(opts, :store), Keyword.fetch!(opts, :session_id))
  catch
    kind, reason ->
      Logger.error(
        "Turn.Server load crashed (session #{inspect(Keyword.fetch!(opts, :session_id))}): " <>
          TurnError.format_raised(kind, reason, __STACKTRACE__)
      )

      normalized =
        kind |> Exception.normalize(reason, __STACKTRACE__) |> TurnError.drop_stacktraces()

      {:error, {:load_crashed, normalized}}
  end

  defp load_session(opts, store, session_id) do
    with {:ok, config, template} <- start_config(opts, store, session_id),
         :ok <- check_server_options(opts, template),
         :ok <- check_hooks(config),
         {:ok, config} <- with_stored_memory(config, store, session_id),
         {:ok, turn_state} <- load_turn_state(store, session_id) do
      {:ok, config, template, turn_state}
    end
  end

  # A saved template's server options are checked with the rest of the load, so
  # init_data/4 never raises on them: a bad value is refused like a bad template.
  defp check_server_options(opts, template) do
    check_template(fn ->
      _ = timeout_options(opts, template)
      :ok
    end)
  end

  defp unavailable(opts, reason) do
    {data, actions} = unavailable_data(opts, reason)
    {:ok, :unavailable, data, actions}
  end

  defp unavailable_data(opts, reason) do
    session_id = Keyword.fetch!(opts, :session_id)

    Logger.warning(
      "Turn.Server could not start session #{inspect(session_id)} " <>
        "(#{describe_reason(reason)}); retrying"
    )

    data = %Data{
      session_id: session_id,
      store: Keyword.fetch!(opts, :store),
      registry: Keyword.fetch!(opts, :registry),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 60_000),
      start_opts: opts,
      retry_ms: @retry_initial_ms
    }

    {data, [{{:timeout, :retry}, @retry_initial_ms, :retry}, idle_timeout(data)]}
  end

  # A handler crash was logged where it happened, and its exception can carry hook data:
  # name the handler only. A refused template's or hook list's message names fields and
  # modules only. Anything else (a store or credential provider reason) is logged by its
  # tag, never its terms (decision 6): a provider's reason can hold its opts or a secret.
  defp describe_reason({:handler_crashed, name, _exception}),
    do: "handler #{inspect(name)} crashed"

  defp describe_reason({tag, message})
       when tag in [:invalid_template, :invalid_hooks] and is_binary(message),
       do: "#{inspect(tag)}: #{message}"

  defp describe_reason({:credential_unavailable, mod, reason}),
    do: "credential provider #{inspect(mod)} failed: #{Describe.reason_tag(reason)}"

  # Logged once, with its stacktrace, where safe_load/1 caught it.
  defp describe_reason({:load_crashed, exception}),
    do: "the load crashed: #{Describe.reason_tag(exception)}"

  defp describe_reason({:store_exit, reason}),
    do: "the session store exited: #{Describe.reason_tag(reason)}"

  defp describe_reason(reason), do: Describe.reason_tag(reason)

  # run/2's error while the session cannot be loaded or started. A hook crash or a store
  # write fault while starting a new session is a turn-failure reason; it is nested as
  # the exception it maps to, so the reply carries no tagged tuple.
  defp session_unavailable({:handler_crashed, _name, _e} = reason),
    do: %TurnError{type: :session_unavailable, reason: TurnError.from_reason(reason)}

  defp session_unavailable({:persist_failed, _r} = reason),
    do: %TurnError{type: :session_unavailable, reason: TurnError.from_reason(reason)}

  # A load that raised, exited or threw: the exception itself, as Exception.normalize/3
  # made it (the log line says it crashed).
  defp session_unavailable({:load_crashed, exception}),
    do: %TurnError{type: :session_unavailable, reason: exception}

  defp session_unavailable(reason),
    do: %TurnError{type: :session_unavailable, reason: TurnError.drop_stacktraces(reason)}

  # Loads the session again. On success the transition is the one init/1 would have
  # made, except that a new session's on_session_start hooks run here, inline: a caller
  # or the retry timer triggered this, and a failure must reach that caller now. The
  # retry timer is cancelled.
  defp retry_load(%Data{start_opts: opts}) do
    with {:ok, config, template, turn_state} <- safe_load(opts),
         {:ok, :idle, data, actions} = init_data(opts, config, template, turn_state),
         {:ok, data} <- start_session_if_new(data) do
      {:ok, {:next_state, :idle, data, [{{:timeout, :retry}, :cancel} | List.wrap(actions)]}}
    end
  end

  # A :config start uses it as given; a thin start rebuilds the config from the
  # template saved in the store, and also returns that template.
  defp start_config(opts, store, session_id) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} ->
        {:ok, config, nil}

      :error ->
        template_provider = Keyword.get(opts, :template_provider)

        with {:ok, tmpl} <- load_config_template(store, session_id),
             :ok <- check_loaded(tmpl),
             {:ok, config} <- reconstruct_config(tmpl, template_provider) do
          {:ok, config, tmpl}
        end
    end
  end

  # llm_call and tool spans read the session id from the config they run with.
  defp with_session_id(nil, _session_id), do: nil
  defp with_session_id(config, session_id), do: %{config | session_id: session_id}

  defp init_data(opts, config, template, turn_state) do
    store = Keyword.fetch!(opts, :store)
    registry = Keyword.fetch!(opts, :registry)
    session_id = Keyword.fetch!(opts, :session_id)
    template_provider = Keyword.get(opts, :template_provider)

    resume_policy =
      case template do
        %{resume_policy: rp} -> rp
        _ -> Keyword.get(opts, :resume_policy, :lazy)
      end

    timeouts = timeout_options(opts, template)

    data = %Data{
      session_id: session_id,
      config: with_session_id(config, session_id),
      store: store,
      registry: registry,
      template_provider: template_provider,
      resume_policy: resume_policy,
      subscriber: Keyword.get(opts, :subscriber),
      # Unwrapped: before_llm and after_compact run apart from the LLM call and the
      # compaction (call_llm_event/3, compact_event/3), so their crashes are told apart.
      handlers: Keyword.get(opts, :handlers) || BaseAgent.non_streaming_handlers(),
      turn_state: turn_state,
      approval_timeout_ms: timeouts.approval_timeout_ms,
      on_approval_timeout: timeouts.on_approval_timeout,
      idle_timeout_ms: timeouts.idle_timeout_ms,
      start_opts: opts
    }

    if data.resume_policy == :eager and resumable?(data.turn_state) do
      {:ok, :idle, data, [{:next_event, :internal, :resume}]}
    else
      {:ok, :idle, data, idle_timeout(data)}
    end
  end

  # A new session's on_session_start hooks run as the first event after init/1 returns,
  # so a slow hook does not block the supervisor starting this server and a crashing one
  # sends it :unavailable instead of failing the start.
  defp with_session_start({:ok, :idle, data, actions} = init) do
    if ServerGlue.session_start?(data.config, data.turn_state),
      do: {:ok, :idle, data, [{:next_event, :internal, :session_start} | List.wrap(actions)]},
      else: init
  end

  defp start_session_if_new(data) do
    if ServerGlue.session_start?(data.config, data.turn_state),
      do: start_session(data),
      else: {:ok, data}
  end

  # Runs on_session_start and stores what it injects as one user message, so the store
  # holds all of it or none: a retry finds the session new again only while nothing was
  # stored.
  defp start_session(data) do
    case call_handler(data, :on_session_start, fn -> ServerGlue.session_start(data.config) end) do
      {:ok, nil} -> {:ok, data}
      {:ok, text} -> store_session_start(data, text)
      {:crashed, reason} -> {:error, reason}
    end
  end

  defp store_session_start(data, text) do
    config = %{data.config | memory: AgentMemory.add_message(data.config.memory, "user", text)}

    case append_to_store(data, config, "user", text, new_entry_id(data.config, config)) do
      :ok -> {:ok, %{data | config: config}}
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  # check_start_source!/2 made sure a thin start has a :template_provider.
  defp load_config_template({mod, handle}, session_id) do
    case store_call(fn -> mod.load_config_template(handle, session_id) end) do
      {:ok, tmpl} -> {:ok, tmpl}
      :error -> {:error, {:no_config_template, session_id}}
      {:error, reason} -> {:error, store_reason(reason)}
    end
  end

  # A hook list this node cannot run (a hook module not deployed here, invalid opts) is
  # reported like a store fault: the server waits :unavailable and retries, instead of
  # failing the start into a supervisor restart loop or running without its hooks.
  defp check_hooks(nil), do: :ok
  defp check_hooks(config), do: Hooks.check_entries(Runner.entries(config))

  # A missing supplement or a failed credential lookup is reported like a store
  # fault, so the server waits :unavailable and retries instead of crashing into a
  # supervisor restart loop. Tier-2 reconstruction needs a node-local credential
  # provider (env/vault); CredentialProvider.FromClient has no client here.
  defp reconstruct_config(tmpl, {tp_mod, tp_handle}) do
    template_id = session_id_template_id(tmpl)
    {cred_mod, cred_opts} = tmpl.behaviours_refs.credential

    with {:supplement, {:ok, supplement}} <- {:supplement, tp_mod.fetch(tp_handle, template_id)},
         {:pinned, :ok} <- {:pinned, check_pinned(tmpl, supplement)},
         {:token, {:ok, token}} <- {:token, cred_mod.get_token(token_provider(tmpl), cred_opts)} do
      {:ok, ConfigTemplate.rebuild(tmpl, supplement, token)}
    else
      {:supplement, :error} -> {:error, {:no_template_supplement, template_id}}
      {:pinned, {:error, _} = error} -> error
      {:token, {:error, reason}} -> {:error, {:credential_unavailable, cred_mod, reason}}
    end
  end

  # check_translatable!/1 makes reconstruct_config/2's reads of :template_id and the
  # credential ref safe: a template missing them is refused here, naming the field or slot.
  defp check_loaded(tmpl) do
    check_template(fn ->
      :ok = ConfigTemplate.check_loaded!(tmpl)
      ConfigTemplate.check_translatable!(tmpl)
    end)
  end

  defp check_pinned(tmpl, supplement),
    do: check_template(fn -> ConfigTemplate.check_pinned!(tmpl, supplement) end)

  # A template the checks refuse is reported like a store fault: the server waits
  # :unavailable instead of crashing its start, and nothing in the template is used. The
  # message names fields and modules, never values.
  defp check_template(check) do
    check.()
  rescue
    e in ArgumentError -> {:error, {:invalid_template, Exception.message(e)}}
  end

  # Rebuild the conversation from the store's history, keeping the configured
  # memory cap (from_entries/1 builds an uncapped memory).
  defp with_stored_memory(nil, _store, _session_id), do: {:ok, nil}

  defp with_stored_memory(config, {mod, handle}, session_id) do
    case store_call(fn -> mod.history(handle, session_id) end) do
      {:ok, entries} ->
        max_messages = config.memory && config.memory.max_messages

        {:ok,
         %{config | memory: %{AgentMemory.from_entries(entries) | max_messages: max_messages}}}

      {:error, reason} ->
        {:error, store_reason(reason)}
    end
  end

  defp load_turn_state({mod, handle}, sid) do
    case store_call(fn -> mod.load_turn_state(handle, sid) end) do
      {:ok, ts} -> {:ok, ts}
      :error -> {:ok, nil}
      {:error, reason} -> {:error, store_reason(reason)}
    end
  end

  # A session store's load reason is replied to every run/2 caller: it is reduced to its
  # tags (Describe.reason_term/1), since a backend's reason can hold a query, a response
  # body or a connection's options.
  defp store_reason(reason), do: Describe.reason_term(reason)

  # A thin start restores the server options saved with the template;
  # explicit start options still win.
  defp timeout_options(opts, template) do
    saved =
      case template do
        %{server_options: saved} when is_map(saved) -> saved
        _ -> %{}
      end

    on_approval_timeout = server_option(opts, saved, :on_approval_timeout, :continue)
    validate_on_approval_timeout!(on_approval_timeout)

    %{
      approval_timeout_ms: server_option(opts, saved, :approval_timeout_ms, 300_000),
      on_approval_timeout: on_approval_timeout,
      idle_timeout_ms: server_option(opts, saved, :idle_timeout_ms, 60_000)
    }
  end

  defp server_option(opts, saved, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Map.get(saved, key, default)
    end
  end

  defp resumable?(%Turn.State{status: status}) when status not in [:stopped, :failed], do: true
  defp resumable?(_), do: false

  defp session_id_template_id(%{template_id: id}), do: id

  # FromClient needs a client carrying :api_key; env/vault providers ignore the
  # first arg. For reconstruction the token must come from a node-local provider,
  # so we pass a minimal provider map derived from the template's model.
  defp token_provider(%{model: model}), do: %{model: model}

  # An approval sent by a caller running an older Normandy (another node during a
  # rolling deploy) carries no approver context.
  @impl true
  def handle_event(:cast, {:approval, decisions}, state, data),
    do: handle_event(:cast, {:approval, decisions, nil}, state, data)

  # :unavailable — the store failed the load at start. A turn request retries it:
  # on success the request is replayed in :idle, otherwise it gets the reason.
  def handle_event({:call, from}, msg, :unavailable, data) when is_turn_request(msg) do
    case retry_load(data) do
      {:ok, {:next_state, state, new_data, actions}} ->
        {:next_state, state, new_data, actions ++ [:postpone]}

      {:error, reason} ->
        {:keep_state_and_data,
         [{:reply, from, {:error, session_unavailable(reason)}}, idle_timeout(data)]}
    end
  end

  # An approval for a session whose turn could not be loaded: load it now, or drop
  # the decision (there is no parked turn to give it to).
  def handle_event(:cast, {:approval, _decisions, _approver_ctx}, :unavailable, data) do
    case retry_load(data) do
      {:ok, {:next_state, state, new_data, actions}} ->
        {:next_state, state, new_data, actions ++ [:postpone]}

      {:error, reason} ->
        Logger.warning(
          "Turn.Server dropped an approval for session #{inspect(data.session_id)}: " <>
            "the session could not be started (#{describe_reason(reason)})"
        )

        :keep_state_and_data
    end
  end

  def handle_event({:timeout, :retry}, :retry, :unavailable, data) do
    case retry_load(data) do
      {:ok, transition} ->
        transition

      {:error, _reason} ->
        retry_ms = min(data.retry_ms * 2, @retry_max_ms)
        {:keep_state, %{data | retry_ms: retry_ms}, [{{:timeout, :retry}, retry_ms, :retry}]}
    end
  end

  # :idle — accept a new turn request (mid-turn requests are postponed; Task 7).
  def handle_event({:call, from}, {:turn, user_input}, :idle, data),
    do: handle_event({:call, from}, {:turn, user_input, nil}, :idle, data)

  def handle_event({:call, from}, {:turn, user_input, caller_ctx}, :idle, data) do
    missing = data.config.memory |> AgentMemory.messages() |> Turn.unanswered_tool_calls()

    # Admission first: a rejected input changes nothing, and the interrupted results the
    # repair builds belong to a turn that runs.
    # begin_turn/2 encodes the input as it appends it, so an input that cannot be
    # encoded fails here, as a crashed :append, before anything reaches the store.
    with {:ok, admitted} <- admit(data, user_input),
         {:ok, repairs} <- close_batch(data, missing),
         {:ok, config} <-
           call_handler(data, :append, fn ->
             BaseAgent.begin_turn(last_config(repairs, data.config), admitted)
           end) do
      start_turn(from, {user_input, caller_ctx}, config, repairs, data)
    else
      {:rejected, exception} ->
        emit_rejected_run(data, caller_ctx, exception)
        :gen_statem.reply(from, {:error, exception})
        turn_end(data, data.config, {:rejected, exception}, turn_id: nil)
        {:keep_state, data}

      {:crashed, reason} ->
        exception = TurnError.from_reason(reason)
        :gen_statem.reply(from, {:error, exception})
        turn_end(data, data.config, {:error, exception}, turn_id: nil)
        {:keep_state, data}
    end
  end

  # The first event of a new session (with_session_start/1). A crash or a store fault
  # sends the server :unavailable, which retries the load and the hook on its backoff
  # and on each run/2, replying the reason meanwhile.
  def handle_event(:internal, :session_start, :idle, data) do
    case start_session(data) do
      {:ok, data} ->
        {:keep_state, data, idle_timeout(data)}

      {:error, reason} ->
        {data, actions} = unavailable_data(data.start_opts, reason)
        {:next_state, :unavailable, data, actions}
    end
  end

  # Eager auto-resume: drive the persisted in-flight turn to completion. No caller
  # is waiting (pending_reply is nil → reply/2 is a no-op), so the turn finalizes
  # silently while persisting at each boundary.
  def handle_event(:internal, :resume, :idle, data) do
    data = start_resumed_run_span(data)

    case close_resumed_batch(data) do
      {:ok, data} ->
        {state, effects} = Turn.resume(data.turn_state)
        interpret(effects, %{data | turn_state: state})

      {:error, data, reason} ->
        fail(data, reason)
    end
  end

  # :running — a monitored Task delivered the outcome of a blocking effect.
  # Compact result carries the updated config alongside the meta; thread both.
  def handle_event(
        :info,
        {task_ref, {:compact_result, config2, meta}},
        :running,
        %Data{task_ref: task_ref} = data
      )
      when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])
    {state, effects} = Turn.step(data.turn_state, {:compaction_done, meta})
    interpret(effects, %{data | turn_state: state, task_ref: nil, config: config2})
  end

  def handle_event(:info, {task_ref, event}, :running, %Data{task_ref: task_ref} = data)
      when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])
    {state, effects} = Turn.step(data.turn_state, event)
    interpret(effects, %{data | turn_state: state, task_ref: nil})
  end

  # A monitored Task died (an exit or a throw; a raise is the worker's own error event,
  # worker_event/4): feed the matching *_error event into the core, as a :task_down
  # TurnError with no stacktrace in it.
  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        :running,
        %Data{task_ref: ref} = data
      ) do
    event = {error_event(data.task_kind), TurnError.task_down(reason)}

    {state, effects} = Turn.step(data.turn_state, event)
    interpret(effects, %{data | turn_state: state, task_ref: nil, task_kind: nil})
  end

  # :awaiting_approval — out-of-band approval decisions for a parked turn.
  # Each call the core will reject (Turn.rejected_calls/2, its own split) gets a
  # [:normandy, :tool, :denied] event here.
  def handle_event(:cast, {:approval, decisions, approver_ctx}, :awaiting_approval, data) do
    %Turn.State{parked_calls: parked} = data.turn_state

    rejected = Turn.rejected_calls(parked, decisions)

    data =
      with_approver_ctx(approver_ctx, data, fn ->
        for call <- rejected do
          Dispatch.emit_denied(data.config, call, :approval_rejected)
        end

        stop_approval_span(data, approval_outcome(length(parked), length(rejected)))
      end)

    interpret_built(data, rejected, Turn.step(data.turn_state, {:approval, decisions}))
  end

  # A stale/duplicate/late approval cast (double-click, or arriving after the turn
  # already resumed or finalized) lands in a state with no parked calls. Drop it
  # rather than let an unhandled event crash (and transient-restart) the server.
  def handle_event(:cast, {:approval, _decisions, _approver_ctx}, _state, _data) do
    :keep_state_and_data
  end

  # Approval window closed with no decision. The core answers every parked call with
  # an expiry result and either continues or fails the turn (on_approval_timeout).
  def handle_event(:state_timeout, :approval_expiry, :awaiting_approval, data) do
    %Turn.State{parked_calls: parked} = data.turn_state
    mode = data.on_approval_timeout
    ms = data.approval_timeout_ms

    :telemetry.execute(
      [:normandy, :turn, :approval, :expired],
      %{count: length(parked)},
      Map.merge(Metadata.ids(data.config), %{
        session_id: data.session_id,
        mode: mode,
        timeout_ms: ms,
        tool_names: Enum.map(parked, & &1.name)
      })
    )

    Enum.each(parked, &Dispatch.emit_denied(data.config, &1, :approval_expired))

    data = stop_approval_span(data, :expired)

    step = Turn.step(data.turn_state, {:approval_expired, %{mode: mode, timeout_ms: ms}})
    interpret_built(data, parked, step)
  end

  # Idle long enough → passivate. Final turn state is already persisted; on_passivate
  # hooks run (logged-only, through call_handler/3), then the server stops. An
  # :unavailable server nobody calls stops too, with no hooks (it loaded no config); the
  # next caller starts it again.
  def handle_event(:state_timeout, :passivate, state, data)
      when state in [:idle, :unavailable] do
    _ =
      if state == :idle and Runner.hooks?(data.config),
        do: call_handler(data, :on_passivate, fn -> Runner.passivate(data.config) end)

    {:stop, :normal, data}
  end

  # A turn request mid-turn is postponed and replayed when we re-enter :idle.
  def handle_event({:call, _from}, msg, state, _data)
      when is_turn_request(msg) and state in [:running, :awaiting_approval] do
    {:keep_state_and_data, :postpone}
  end

  # Anything else that lands in the mailbox: a late result from a task whose ref was
  # already cleared, an unrelated :DOWN or :EXIT, a stray send/2. Drop it with a log
  # line instead of raising FunctionClauseError (which would crash the server). A
  # late `{ref, _}` result also drops the monitor it was never matched against.
  def handle_event(:info, msg, state, data) do
    case msg do
      {ref, _result} when is_reference(ref) and ref != data.task_ref ->
        Process.demonitor(ref, [:flush])

      _ ->
        :ok
    end

    Logger.debug(
      "Turn.Server #{inspect(data.session_id)} ignored a stray message in #{inspect(state)}: " <>
        inspect(msg, limit: 5, printable_limit: 100)
    )

    :keep_state_and_data
  end

  # The server ends a run span left in flight (between the hand-emitted run :start and
  # its :stop/:exception) with a run :exception of kind :exit. The server does not trap
  # exits, so this runs on callback-initiated stops ({:stop, ...}, passivation) and
  # :gen_statem.stop/3. A supervisor's shutdown is an exit signal, which without
  # trap_exit ends the process with no callback, as do :kill and a linked process dying.
  @impl true
  def terminate(reason, _state, data) do
    data = stop_approval_span(data, :terminated)

    stop_run_span(data, :exception, Span.exception_metadata(:exit, reason, []))
  end

  # What a crash report, :sys.get_status/1 and the observer show of this server: its ids
  # and state names, never the conversation (the config's memory, the start options'
  # second config, the turn state's responses) nor the user input in a queued or
  # postponed turn request (decision 6). format_status/1 is OTP 25+; OTP 24 calls
  # format_status/2.
  if String.to_integer(List.to_string(:erlang.system_info(:otp_release))) >= 25 do
    @impl true
    def format_status(status) do
      status
      |> Map.update(:data, nil, &status_data/1)
      |> Map.update(:queue, [], &length/1)
      |> Map.update(:postponed, [], &length/1)
      |> Map.update(:log, [], &length/1)
    end
  else
    @impl true
    def format_status(_opt, [_pdict, state, data]),
      do: [data: [{~c"State", {state, status_data(data)}}]]
  end

  defp status_data(%Data{} = data) do
    %{
      session_id: data.session_id,
      turn_status: data.turn_state && data.turn_state.status,
      task_kind: data.task_kind,
      resume_policy: data.resume_policy
    }
  end

  defp status_data(_other), do: :redacted

  defp validate_on_approval_timeout!(mode) when mode in [:continue, :fail], do: :ok

  defp validate_on_approval_timeout!(other) do
    raise ArgumentError,
          "Normandy.Agents.Turn.Server: the saved template's :on_approval_timeout must be " <>
            ":continue or :fail, got: #{inspect(other)}"
  end

  # Schema, input-guardrail and on_prompt-hook rejections are expected outcomes: reply
  # them as data without touching state. Anything else admission raises, exits or throws
  # (a hook or input guardrail crashing under on_error: :reraise, a hook's contract
  # violation) is {:crashed, {:handler_crashed, :admit, e}}, replied as a :handler_crashed
  # TurnError, instead of crashing the session (and, through restart intensity,
  # Turn.Supervisor).
  defp admit(data, user_input) do
    {:ok, BaseAgent.admit_input!(data.config, user_input)}
  rescue
    e in [Normandy.Schema.ValidationError, Normandy.Guardrails.ViolationError] ->
      {:rejected, e}

    # An on_prompt halt, the only halt admission runs: {:rejected, e}.
    e in Normandy.HookHaltError ->
      Normandy.HookHaltError.outcome(e)
  catch
    kind, reason -> handler_crash(data, :admit, kind, reason, __STACKTRACE__)
  end

  # Store order mirrors memory order: interrupted results, then the user message.
  # Memory must end up holding exactly what reached the store: a failed write keeps
  # the config as of the last stored result, so the next turn repairs only the rest.
  defp start_turn(from, {user_input, caller_ctx}, config, repairs, data) do
    config = BaseAgent.with_default_output_schema(config)

    with {:ok, repaired} <- persist_interrupted(data, repairs),
         :ok <- persist_user_message(data, config, user_input, repaired) do
      state =
        Turn.new(
          max_iterations: config.max_tool_iterations,
          response_model: BaseAgent.turn_response_model(config),
          output_schema: config.output_schema
        )

      # The caller's context, persisted with every save of the turn state, so a
      # restarted server can resume the turn in the caller's trace.
      state = %{state | trace_carrier: OtelCtx.inject(caller_ctx)}

      run_span = start_run_span(data, config, caller_ctx, Metadata.turn_id(config))

      data = %{
        data
        | config: config,
          pending_reply: from,
          run_span: run_span,
          approval_wait: 0
      }

      {state, effects} = Turn.step(state, :start)
      interpret(effects, %{data | turn_state: state})
    else
      {:error, stored, reason} ->
        :gen_statem.reply(from, persist_failed(reason))
        turn_end(data, config, persist_failed(reason))
        {:keep_state, %{data | config: stored}}
    end
  end

  defp persist_failed(reason), do: {:error, %TurnError{type: :persist_failed, reason: reason}}

  # The [:normandy, :agent, :run, *] events BaseAgent.run/2 emits. A turn spans
  # several gen_statem events, so :start and :stop/:exception are emitted by
  # hand. A turn resumed by a restarted server gets its own :start (resumed: true).
  #
  # The caller's OTel context is attached in this (long-lived) process before
  # :start, so a bridged run span nests under the caller's span; stop_run_span/3
  # detaches it again so it does not leak into the next turn.
  defp start_run_span(data, config, caller_ctx, turn_id, extra_meta \\ %{}) do
    caller_ctx_token = OtelCtx.attach(caller_ctx)

    meta =
      %{session_id: data.session_id}
      |> Map.merge(Metadata.run(config, turn_id: turn_id))
      |> Map.merge(extra_meta)
      |> Map.put(:telemetry_span_context, make_ref())

    start = System.monotonic_time()

    :telemetry.execute(
      [:normandy, :agent, :run, :start],
      %{system_time: System.system_time(), monotonic_time: start},
      meta
    )

    %{start: start, meta: meta, caller_ctx_token: caller_ctx_token}
  end

  # Rejected input never starts a turn, but BaseAgent.run/2 reports it as a run span
  # that ends in :exception with the exception as its reason; do the same here. The
  # turn id is left out: admission raised before a turn was initialised.
  defp emit_rejected_run(data, caller_ctx, exception) do
    span = start_run_span(data, data.config, caller_ctx, nil)

    stop_run_span(
      %{data | run_span: span, approval_wait: 0},
      :exception,
      Span.exception_metadata(:error, exception, [])
    )
  end

  # The run span of a turn a restarted server resumes, under the original caller's
  # context rebuilt from the persisted carrier (see "Telemetry" in the moduledoc).
  # Map.get: a Turn.State persisted before trace_carrier existed decodes without it.
  defp start_resumed_run_span(data) do
    caller_ctx = data.turn_state |> Map.get(:trace_carrier, []) |> OtelCtx.extract()
    turn_id = Metadata.turn_id(data.config)
    run_span = start_run_span(data, data.config, caller_ctx, turn_id, %{resumed: true})
    %{data | run_span: run_span, approval_wait: 0}
  end

  defp stop_run_span(%Data{run_span: nil}, _event, _extra), do: :ok

  defp stop_run_span(%Data{run_span: %{start: start, meta: meta} = span} = data, event, extra) do
    now = System.monotonic_time()

    :telemetry.execute(
      [:normandy, :agent, :run, event],
      %{duration: now - start, monotonic_time: now, approval_wait: data.approval_wait},
      Map.merge(meta, extra)
    )

    OtelCtx.detach(span.caller_ctx_token)
  end

  # The [:normandy, :turn, :approval, :start | :stop] span around one park. Hand-emitted
  # (not :telemetry.span/3) because the park and the resume are different callbacks.
  # Both events carry the same telemetry_span_context so bridges can pair them. A turn
  # re-entering :awaiting_approval after a restart (durable resume) opens a fresh span
  # inside the resumed run's span; the earlier span died with the old process.
  #
  # outer_ctx is the OTel context current before :start (the run's), which
  # with_approver_ctx/3 makes current again after the approval is handled.
  defp start_approval_span(%Data{approval_span: nil} = data) do
    parked = data.turn_state.parked_calls
    outer_ctx = OtelCtx.capture()
    start = System.monotonic_time()

    meta =
      Map.merge(Metadata.ids(data.config), %{
        session_id: data.session_id,
        tool_names: Enum.map(parked, & &1.name),
        count: length(parked),
        telemetry_span_context: make_ref()
      })

    :telemetry.execute(
      [:normandy, :turn, :approval, :start],
      %{system_time: System.system_time(), monotonic_time: start},
      meta
    )

    %{data | approval_span: %{start: start, meta: meta, outer_ctx: outer_ctx}}
  end

  defp start_approval_span(data), do: data

  # Closes the open approval span (no-op when none is open) and adds its duration to
  # the turn's approval_wait. outcome: :approved | :rejected | :mixed | :expired, or
  # :terminated when the server stops while parked.
  defp stop_approval_span(%Data{approval_span: nil} = data, _outcome), do: data

  defp stop_approval_span(%Data{approval_span: %{start: start, meta: meta}} = data, outcome) do
    now = System.monotonic_time()
    duration = now - start

    :telemetry.execute(
      [:normandy, :turn, :approval, :stop],
      %{duration: duration, monotonic_time: now},
      Map.put(meta, :outcome, outcome)
    )

    %{data | approval_span: nil, approval_wait: data.approval_wait + duration}
  end

  # Runs `fun` (which closes the approval span) with the approver's context current,
  # then makes the run's context current again so the work after the approval is not
  # reparented. Not OtelCtx.detach/1: a bridge that ended a bridged approval span on
  # :stop has already put back the context current at its :start, and detaching our
  # token would then make the ended approval span current again.
  defp with_approver_ctx(nil, _data, fun), do: fun.()

  defp with_approver_ctx(approver_ctx, data, fun) do
    outer_ctx =
      case data.approval_span do
        %{outer_ctx: ctx} -> ctx
        nil -> OtelCtx.capture()
      end

    _token = OtelCtx.attach(approver_ctx)
    result = fun.()
    _token = OtelCtx.attach(outer_ctx)
    result
  end

  defp approval_outcome(_total, 0), do: :approved
  defp approval_outcome(total, total), do: :rejected
  defp approval_outcome(_total, _rejected), do: :mixed

  defp last_config([], default), do: default
  defp last_config(repairs, _default), do: repairs |> List.last() |> elem(2)

  # A failed or killed turn can leave the last assistant tool_use without results;
  # the Claude API rejects the next request unless every tool_use is answered. Fold
  # an interrupted result per missing call into memory (no turn exists yet, so a
  # crashing append or hook replies instead of going through fail/2). Each result
  # passes after_tool first, like any result the model sees; callers admit the turn's
  # input before this, so a rejected input reports none. Returns one
  # {call, result, config_after_this_result} per missing call.
  defp close_batch(_data, []), do: {:ok, []}

  defp close_batch(data, missing) do
    with {:ok, results} <-
           call_handler(data, :after_tool, fn -> interrupted_results(data.config, missing) end) do
      call_handler(data, :append, fn ->
        {repairs, _config} =
          missing
          |> Enum.zip(results)
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          |> Enum.map_reduce(data.config, fn {call, result}, config ->
            folded = data.handlers.append.(config, "tool", result)
            {{call, result, folded}, folded}
          end)

        repairs
      end)
    end
  end

  defp interrupted_results(config, missing),
    do: Enum.map(missing, &ServerGlue.after_tool(config, &1, interrupted_result(&1)))

  # :steering is persisted once per tool batch, so a server killed while a later
  # batch ran restarts from a :steering state whose history already ends in that
  # batch's unanswered tool_use. Close it before resuming the LLM call. A parked
  # turn (:awaiting_approval) is left alone: its unanswered calls await a decision.
  defp close_resumed_batch(%Data{turn_state: %Turn.State{status: :steering}} = data) do
    missing = data.config.memory |> AgentMemory.messages() |> Turn.unanswered_tool_calls()

    with {:ok, repairs} <- close_batch(data, missing),
         {:ok, repaired} <- persist_interrupted(data, repairs) do
      {:ok, %{data | config: repaired}}
    else
      {:crashed, reason} -> {:error, data, reason}
      {:error, stored, reason} -> {:error, %{data | config: stored}, {:persist_failed, reason}}
    end
  end

  defp close_resumed_batch(data), do: {:ok, data}

  defp interrupted_result(call) do
    Dispatch.error_result(
      Map.get(call, :id),
      "tool call interrupted: the previous turn ended before a result was recorded; " <>
        "the tool may or may not have run. Check the current state before repeating it.",
      %{interrupted: true}
    )
  end

  # Returns {:ok, config} with every result folded, or {:error, config, reason} where
  # config holds only the results that reached the store.
  defp persist_interrupted(data, repairs) do
    result =
      Enum.reduce_while(repairs, {:ok, data.config}, fn {_call, result, folded}, {:ok, prev} ->
        case append_to_store(data, data.config, "tool", result, new_entry_id(prev, folded)) do
          :ok -> {:cont, {:ok, folded}}
          {:error, reason} -> {:halt, {:error, prev, reason}}
        end
      end)

    if match?({:ok, _}, result), do: log_repair(data, repairs)
    result
  end

  defp log_repair(_data, []), do: :ok

  defp log_repair(data, repairs) do
    Logger.warning(
      "Turn.Server closed #{length(repairs)} interrupted tool call(s) left by a previous " <>
        "turn (session #{inspect(data.session_id)}): " <>
        Enum.map_join(repairs, ", ", fn {call, _, _} -> to_string(Map.get(call, :name)) end)
    )
  end

  # ---- effect interpreter ----
  # Processes effects left-to-right. Non-blocking effects run synchronously and
  # advance the core in-line (convert/validate/guard) or just side-effect
  # (append/emit/persist). A blocking effect spawns a monitored Task and parks in
  # :running. {:finalize}/{:fail} reply and return to :idle.

  # The core answers rejected and expired calls itself. Their results pass after_tool
  # here, in the callback whose step built them (in the append effects it returned, or
  # in the held results it keeps while approved calls run), so each passes exactly once
  # and no state outlives the callback. A crashing hook fails the turn like a crashing
  # handler; the next turn repairs the batch's unanswered calls.
  defp interpret_built(data, calls, {state, effects}) do
    case call_handler(data, :after_tool, fn ->
           ServerGlue.after_tool_built(data.config, calls, {state, effects})
         end) do
      {:ok, {state, effects}} -> interpret(effects, %{data | turn_state: state})
      {:crashed, reason} -> fail(%{data | turn_state: state}, reason)
    end
  end

  defp interpret([], %Data{turn_state: %Turn.State{status: :awaiting_approval}} = data) do
    data = start_approval_span(data)

    {:next_state, :awaiting_approval, data,
     {:state_timeout, data.approval_timeout_ms, :approval_expiry}}
  end

  defp interpret([], data), do: {:keep_state, data}

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp interpret([effect | rest], data) do
    case effect do
      {:emit_event, name, meta} ->
        guarded(data, :emit, fn -> emit(data, name, meta) end, fn _ -> interpret(rest, data) end)

      {:append_message, role, content} ->
        guarded(
          data,
          :append,
          fn -> data.handlers.append.(data.config, role, content) end,
          fn config ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case append_to_store(data, config, role, content, new_entry_id(data.config, config)) do
              :ok -> interpret(rest, %{data | config: config})
              # Memory must match the store: do not adopt `config` when the write failed,
              # so the next turn's repair sees exactly what the store lacks.
              {:error, reason} -> fail(data, {:persist_failed, reason})
            end
          end
        )

      {:persist, turn_state} ->
        case persist_turn_state(data, turn_state) do
          :ok -> interpret(rest, data)
          {:error, reason} -> fail(data, {:persist_failed, reason})
        end

      {:convert_output, raw, schema} ->
        # An answer that does not parse into the output schema fails the turn with the
        # :invalid_output LLMError run/2 returns, not a handler crash.
        guarded(
          data,
          :convert,
          fn -> convert_output(data, raw, schema) end,
          fn
            {:output_unparsed, e} -> fail(data, e)
            converted -> advance(rest, data, {:output_converted, converted})
          end
        )

      {:validate_output, value} ->
        # An output that breaks its schema is a rejection of the answer, not a crash.
        guarded(
          data,
          :validate,
          fn -> validate_output(data, value) end,
          fn
            {:output_unparsed, e} -> fail(data, e)
            {:output_invalid, e} -> fail(data, {:rejected, e})
            validated -> advance(rest, data, {:output_validated, validated})
          end
        )

      {:guard_output, value} ->
        # An output guardrail block is a rejection of the answer, not a crash.
        guarded(
          data,
          :guard,
          fn -> guard_output(data, value) end,
          fn
            {:output_rejected, e} -> fail(data, {:rejected, e})
            _ -> advance(rest, data, {:output_guarded, value})
          end
        )

      {:call_llm, request} ->
        spawn_task(data, :llm, &call_llm_event(&1, &2, request))

      {:dispatch_tools, calls} ->
        spawn_task(data, :tools, fn _h, d -> dispatch(d, calls) end)

      {:execute_approved, calls} ->
        spawn_task(data, :tools, fn _h, d ->
          {:approved_results, execute_approved(d, calls)}
        end)

      {:maybe_compact, info} ->
        spawn_task(data, :compact, &compact_event(&1, &2, info))

      {:finalize, value} ->
        # Persist the terminal (:stopped) turn state so the resume reaper can tell a
        # completed session from a mid-turn one. Best-effort: the turn already
        # succeeded, so a failed marker-persist must not fail it.
        _ = persist_turn_state(data, data.turn_state)
        stop_run_span(data, :stop, %{})
        reply(data, {:ok, value})
        turn_end(data, data.config, {:ok, value})
        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil}, idle_timeout(data)}

      {:fail, reason} ->
        # Persist the terminal (:failed) turn state (best-effort) for the same reason.
        _ = persist_turn_state(data, data.turn_state)
        exception = TurnError.from_reason(reason)
        stop_run_span(data, :exception, Span.exception_metadata(:error, exception, []))
        reply(data, {:error, exception})
        turn_end(data, data.config, ServerGlue.fail_outcome(reason))
        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil}, idle_timeout(data)}
    end
  end

  # `advance` feeds an in-line (non-blocking) result back into the core and keeps
  # interpreting — convert/validate/guard never leave the current handler.
  defp advance(rest, data, event) do
    {state, effects} = Turn.step(data.turn_state, event)
    interpret(effects ++ rest, %{data | turn_state: state})
  end

  # The worker's event for a :call_llm effect. before_llm runs first, apart from the
  # call: a halt fails the turn with {:hook_halted, e}, a crash with {:handler_crashed,
  # :before_llm, e}. A raise in the call itself fails it with that exception
  # (worker_event/4), an exit or throw with a :task_down TurnError.
  defp call_llm_event(handlers, data, request) do
    with {:ok, :ok} <-
           worker_hook(data, :before_llm, fn ->
             ServerGlue.before_llm(handlers, data.config, data.turn_state, request)
           end) do
      {:llm_response, handlers.call_llm.(data.config, data.turn_state, request)}
    end
  end

  # The worker's event for a :maybe_compact effect, carrying the updated config. A
  # compactor crash fails the turn as a crash in the LLM call does (call_llm_event/3); an
  # after_compact crash after it fails the turn with {:handler_crashed, :after_compact, e}.
  defp compact_event(handlers, data, info) do
    compacted = handlers.compact.(data.config, data.turn_state, info)

    with {:ok, {config, meta}} <-
           worker_hook(data, :after_compact, fn ->
             ServerGlue.after_compact(handlers, data.config, data.turn_state, info, compacted)
           end) do
      {:compact_result, config, meta}
    end
  end

  # Runs a hook event in the worker task. A halt or a crash (logged by handler_crash/5)
  # becomes the :llm_error event that fails the turn, instead of the worker's death.
  defp worker_hook(data, event, fun) do
    {:ok, fun.()}
  rescue
    e in Normandy.HookHaltError -> {:llm_error, {:hook_halted, e}}
  catch
    kind, reason ->
      {:crashed, crash} = handler_crash(data, event, kind, reason, __STACKTRACE__)
      {:llm_error, crash}
  end

  # Spawn a MONITORED, UNLINKED task that computes its event and sends it back
  # as {ref, event} where ref is the monitor reference; transition to :running.
  # Unlinked + monitored means a Task crash delivers {:DOWN, ref, ...} (handled
  # by the :running :DOWN clause → fails the turn gracefully) WITHOUT taking
  # down this gen_statem. The spawned process waits for the monitor ref before
  # replying so the result is tagged with the same ref the :DOWN would carry.
  #
  # The worker gets this process's OTel context (the run span's, when a bridge
  # made it current at run :start), so its llm_call and tool spans nest under run.
  defp spawn_task(data, kind, fun) do
    server = self()
    handlers = data.handlers
    current = data
    otel_ctx = OtelCtx.capture()

    pid =
      spawn(fn ->
        ref =
          receive do
            {:monitor_ref, r} -> r
          end

        run_while_server_alive(server, ref, fn ->
          OtelCtx.restore(otel_ctx)
          worker_event(kind, fun, handlers, current)
        end)
      end)

    ref = Process.monitor(pid)
    send(pid, {:monitor_ref, ref})
    {:next_state, :running, %{data | task_ref: ref, task_kind: kind}}
  end

  # A raise in the LLM call, the compactor or the tool dispatch fails the turn with
  # that exception instead of killing the worker. Normandy's own exceptions (a 429's
  # LLMError) are expected outcomes and are not logged; anything else is a bug and is
  # logged here with its stacktrace (arities only), the one place the stacktrace goes.
  defp worker_event(kind, fun, handlers, data) do
    fun.(handlers, data)
  rescue
    e ->
      unless TurnError.domain?(e) do
        Logger.error(
          "Turn.Server #{kind} worker raised (session #{inspect(data.session_id)}): " <>
            TurnError.format_raised(:error, e, __STACKTRACE__)
        )
      end

      {error_event(kind), e}
  end

  defp error_event(:tools), do: :tool_error
  defp error_event(_llm_or_compact), do: :llm_error

  # The work runs in a linked worker while this process watches the server: if
  # the server dies, the worker is killed, so an LLM call or tool does not run
  # on unseen (and run again by the restarted server). A worker crash exits
  # this process with the same reason, which the server sees as {:DOWN, ...}.
  defp run_while_server_alive(server, ref, work) do
    server_ref = Process.monitor(server)
    Process.flag(:trap_exit, true)
    watcher = self()
    worker = spawn_link(fn -> send(watcher, {:task_result, work.()}) end)

    receive do
      {:task_result, result} -> send(server, {ref, result})
      {:EXIT, ^worker, reason} -> exit(reason)
      {:DOWN, ^server_ref, :process, _pid, _reason} -> Process.exit(worker, :kill)
    end
  end

  # The shell-level bypass to the terminal :fail effect (used when an append/persist
  # side-effect fails mid-turn, NOT via Turn.step). Force the turn_state to :failed so
  # the terminal state persisted in the {:fail, _} clause is genuinely terminal — the
  # resume reaper must not see a mid-turn status (e.g. :tool_dispatch, :steering) here.
  defp fail(%Data{turn_state: %Turn.State{} = ts} = data, reason),
    do: interpret([{:fail, reason}], %{data | turn_state: %{ts | status: :failed, error: reason}})

  defp fail(data, reason), do: interpret([{:fail, reason}], data)

  # ---- side-effect helpers ----

  # The agent's own emit handler first (a crash there is a handler crash), then the
  # subscriber, whose crash is logged and reported but never fails the turn.
  defp emit(%Data{handlers: handlers} = data, name, meta) do
    if handlers.emit, do: handlers.emit.(data.config, name, meta)
    notify_subscriber(data, name, meta)
  end

  defp notify_subscriber(%Data{subscriber: nil}, _name, _meta), do: :ok

  defp notify_subscriber(%Data{subscriber: sub} = data, name, meta) when is_function(sub, 2) do
    sub.(name, meta)
    :ok
  catch
    kind, reason ->
      Logger.error(
        "Turn.Server subscriber crashed on #{inspect(name)} " <>
          "(session #{inspect(data.session_id)}): " <>
          TurnError.format_raised(kind, reason, __STACKTRACE__)
      )

      :telemetry.execute(
        [:normandy, :turn, :subscriber, :exception],
        %{count: 1},
        %{session_id: data.session_id, event: name, kind: kind}
      )

      :ok
  end

  # Runs a synchronous handler in the server process. A raise, exit or throw becomes
  # {:crashed, {:handler_crashed, name, exception_or_term}} instead of crashing the
  # session (and, through restart intensity, Turn.Supervisor).
  defp call_handler(data, name, fun) do
    {:ok, fun.()}
  catch
    kind, reason -> handler_crash(data, name, kind, reason, __STACKTRACE__)
  end

  # on_turn_end is logged-only (the Runner logs a crashing hook and ignores its return);
  # call_handler/3 is the belt over those braces. Callers run it after the reply.
  defp turn_end(data, config, outcome, ctx_opts \\ []) do
    _ =
      if Runner.hooks?(config),
        do: call_handler(data, :on_turn_end, fn -> Runner.turn_end(config, outcome, ctx_opts) end)

    :ok
  end

  # Logs a crash in a handler or hook the server ran (never its values, see
  # TurnError.format_raised/3) and returns {:crashed, {:handler_crashed, name, exception_or_term}}.
  defp handler_crash(data, name, kind, reason, stacktrace) do
    Logger.error(
      "Turn.Server handler #{inspect(name)} crashed (session #{inspect(data.session_id)}): " <>
        TurnError.format_raised(kind, reason, stacktrace)
    )

    # The reason is persisted with the failed turn state: no stacktrace in it (an exit
    # can carry one, like a GenServer.call to a process that raised).
    normalized = kind |> Exception.normalize(reason, stacktrace) |> TurnError.drop_stacktraces()
    {:crashed, {:handler_crashed, name, normalized}}
  end

  defp guard_output(data, value) do
    data.handlers.guard.(data.config, value)
  rescue
    e in Normandy.Guardrails.ViolationError -> {:output_rejected, e}
  end

  defp convert_output(data, raw, schema) do
    data.handlers.convert.(data.config, raw, schema)
  rescue
    e in Normandy.LLMError -> {:output_unparsed, e}
  end

  # A blank chat answer is the :invalid_output LLMError run/2 returns (decision 22).
  defp validate_output(data, value) do
    data.handlers.validate.(data.config, value)
  rescue
    e in Normandy.Schema.ValidationError -> {:output_invalid, e}
    e in Normandy.LLMError -> {:output_unparsed, e}
  end

  defp guarded(data, name, fun, continue) do
    case call_handler(data, name, fun) do
      {:ok, value} -> continue.(value)
      {:crashed, reason} -> fail(data, reason)
    end
  end

  defp reply(%Data{pending_reply: nil}, _msg), do: :ok
  defp reply(%Data{pending_reply: from}, msg), do: :gen_statem.reply(from, msg)

  defp idle_timeout(%Data{idle_timeout_ms: ms}), do: {:state_timeout, ms, :passivate}

  # When the server was started under a `{:via, _, _}` name, the via callback
  # already registered it; only self-register otherwise.
  defp register_self(%Data{registry: {mod, handle}, session_id: sid}) do
    case child_name_for(mod, handle, sid) do
      :self_register -> mod.register(handle, sid, self())
      {:via, _via_mod, _term} -> :ok
    end
  end

  defp child_name_for(mod, handle, sid) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :child_name, 2),
      do: mod.child_name(handle, sid),
      else: :self_register
  end

  # A failed turn's error is persisted as the exception the turn failed with, redacted
  # (TurnError.redact/1): a bug's fields and message never reach the store.
  defp persist_turn_state(%Data{store: {mod, handle}, session_id: sid}, turn_state),
    do: store_call(fn -> mod.save_turn_state(handle, sid, persistable(turn_state)) end)

  # A store call that exits (a GenServer or Agent call timeout, a dead store process, a
  # dead connection) fails like the store's own {:error, reason}: the write is not
  # adopted and the turn fails :persist_failed, or the load leaves the server
  # :unavailable. The exit reason loses its stacktraces and a call's arguments (they hold
  # the entry being written). A raise is a bug in the store and still raises mid-turn
  # (decision 15c); during the load safe_load/1 catches it.
  defp store_call(fun) do
    fun.()
  catch
    :exit, reason ->
      {:error, {:store_exit, reason |> TurnError.drop_stacktraces() |> TurnError.redact()}}
  end

  defp persistable(%Turn.State{error: nil} = turn_state), do: turn_state

  defp persistable(%Turn.State{error: reason} = turn_state),
    do: %{turn_state | error: reason |> TurnError.from_reason() |> TurnError.redact()}

  # The entry carries the turn id the memory gave this message, so a memory rebuilt from
  # the store keeps the turn boundaries, and the entry id the memory gave it, so a
  # rehydrated memory has the ids the live one had (after_compact hooks deduplicate on
  # them).
  defp append_to_store(%Data{store: {mod, handle}, session_id: sid}, config, role, content, id) do
    entry = %AgentMemory.Entry{
      id: id,
      turn_id: current_turn_id(config),
      role: role,
      content: content
    }

    case store_call(fn -> mod.append_entry(handle, sid, entry) end) do
      {:ok, _id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The id of the entry `after_config`'s memory gained over `before`'s; nil when the
  # append handler added none (the store then assigns one).
  defp new_entry_id(%{memory: %AgentMemory{head: head}}, %{memory: %AgentMemory{head: head}}),
    do: nil

  defp new_entry_id(_before, %{memory: %AgentMemory{head: head}}), do: head
  defp new_entry_id(_before, _after), do: nil

  defp current_turn_id(%{memory: %AgentMemory{current_turn_id: id}}), do: id
  defp current_turn_id(_config), do: nil

  # On failure, carries the repaired config so memory keeps matching the store.
  # Stores the admitted input (e.g. a map cast to the input schema), the value
  # admission put in memory, not the raw argument.
  defp persist_user_message(_data, _config, nil, _repaired), do: :ok

  defp persist_user_message(data, config, _user_input, repaired) do
    id = new_entry_id(repaired, config)

    with {:error, reason} <-
           append_to_store(data, config, "user", config.current_user_input, id),
         do: {:error, repaired, reason}
  end

  # Classify every call; execute the allowed ones concurrently (mirrors
  # BaseAgent.dispatch_turn_tools/2's Task.async_stream); collect held results.
  # If any call needs approval, park the batch; else hand back ordered results.
  defp dispatch(%Data{config: config}, calls) do
    pipeline = BaseAgent.base_agent_pipeline(config)
    max_conc = max(config.max_tool_concurrency || 1, 1)
    parent_ctx = OtelCtx.capture()

    classified =
      calls
      |> Enum.map(&Dispatch.to_tool_call/1)
      |> Enum.map(fn call -> {call, Dispatch.classify(config, call, pipeline)} end)

    parked =
      for {call, {:needs_approval, _p, ncall, _info}} <- classified, do: %{ncall | id: call.id}

    runnable = for {_call, {:execute, invocation, ncall}} <- classified, do: {invocation, ncall}
    denied = for {_call, {:deny, %_{} = result}} <- classified, do: result

    executed =
      runnable
      |> Task.async_stream(
        fn {invocation, ncall} ->
          OtelCtx.restore(parent_ctx)
          Dispatch.execute(config, invocation, ncall, pipeline)
        end,
        ordered: true,
        max_concurrency: max_conc,
        timeout: :infinity,
        on_timeout: :kill_task
      )
      |> Enum.map(&BaseAgent.unwrap_tool_task_result!/1)

    # Back in the batch's tool_use order, as the Driver shell returns them.
    order = classified |> Enum.with_index() |> Map.new(fn {{call, _}, i} -> {call.id, i} end)
    held = Enum.sort_by(executed ++ denied, &Map.fetch!(order, &1.tool_call_id))

    if parked == [] do
      {:tool_results, held}
    else
      {:needs_approval, held, parked}
    end
  end

  # Run already-approved calls through Dispatch.execute_approved/3 (toolset lookup and
  # input validation again, deterministic, no policy). NOT re-classify — re-running
  # policy would re-park. Concurrency mirrors dispatch/2.
  defp execute_approved(%Data{config: config}, calls) do
    pipeline = BaseAgent.base_agent_pipeline(config)
    max_conc = max(config.max_tool_concurrency || 1, 1)
    parent_ctx = OtelCtx.capture()

    calls
    |> Task.async_stream(
      fn %ToolCall{} = call ->
        OtelCtx.restore(parent_ctx)
        Dispatch.execute_approved(config, call, pipeline)
      end,
      ordered: true,
      max_concurrency: max_conc,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Enum.map(&BaseAgent.unwrap_tool_task_result!/1)
  end
end
