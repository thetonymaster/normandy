defmodule Normandy.Agents.Turn.Server do
  @moduledoc """
  Asynchronous `:gen_statem` interpreter of the pure `Turn` FSM — the async analog
  of `Turn.Driver`. Coarse lifecycle states (`:running`, `:awaiting_approval`,
  `:idle`) hang Tasks and `state_timeout`s off the turn; they are NOT a
  re-encoding of the seven `Turn.State` statuses (the core stays the source of
  truth). Blocking effects (`:call_llm`, `:dispatch_tools`, `:execute_approved`)
  run in a monitored Task; non-blocking effects run synchronously in the handler.

  ## Options (besides `:session_id`, `:store`, `:registry`, `:config` / `:template_provider`)

    * `:handlers` — a `Turn.Driver.Handlers` set (default
      `BaseAgent.non_streaming_handlers/0`). A `nil` `:emit` is skipped.
    * `:subscriber` — `fn event_name, meta -> any end`, called in the server process
      for every event. A crash in it is logged, reported as
      `[:normandy, :turn, :subscriber, :exception]` telemetry, and ignored.
    * `:approval_timeout_ms` — how long a parked turn waits for `approve/2`
      (default 300_000).
    * `:on_approval_timeout` — `:continue` (default) or `:fail`. On expiry every
      parked call gets an `expired: true` tool result. `:continue` hands it to the
      model; `:fail` ends the turn with `{:error, {:approval_timeout, ids}}`.
      Expiry emits `[:normandy, :turn, :approval, :expired]` for the batch and a
      `[:normandy, :tool, :denied]` (reason `:approval_expired`) per call; a
      rejected call emits `[:normandy, :tool, :denied]` with `:approval_rejected`.
    * `:idle_timeout_ms` — idle time before passivation (default 60_000).

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
  the store fails that load, the start still succeeds: the server waits in
  `:unavailable`, retries the load on a backoff timer (200 ms doubling to 30 s) and
  on every `run/2`, and replies `{:error, reason}` with the store's reason until a
  load succeeds. It then carries on as a normal start would, eager resume included.
  An approval that arrives while the load fails is dropped with a warning. With no
  call for `:idle_timeout_ms`, the server stops normally.

  ## Events (`:subscriber`)

    * `:iteration` — `%{iteration: n, iterations_left: m, final: boolean}` before each
      LLM call; `final: true` marks the forced-final call after the budget is spent.
    * `:steering` — `%{iterations_left: m}` after a tool batch, once its state is saved.
    * `:awaiting_approval` — `%{parked: n, resumed: boolean}` when a batch parks, and
      again (`resumed: true`) when a restarted server resumes a parked turn.
    * `:approval_expired` — `%{expired: n, mode: :continue | :fail}`.

  ## Telemetry

  Each turn started by `run/2` emits `[:normandy, :agent, :run, :start]`, then
  `:stop` or `:exception` (`kind: :error`, `reason`), with `model`, `agent_name`
  and `session_id` metadata, like `BaseAgent.run/2`.

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

    * `{:rejected, exception}` — the input failed its schema
      (`Normandy.Schema.ValidationError`) or an input guardrail
      (`Normandy.Guardrails.ViolationError`), and nothing was persisted; or an
      output guardrail blocked the answer (`Normandy.Guardrails.ViolationError`),
      and the answer was not saved (the user message was).
    * `{:handler_crashed, name, exception_or_term}` — a synchronous handler
      (`:append`, `:convert`, `:validate`, `:guard`, `:emit`) raised, exited or threw.
    * `{:approval_timeout, [tool_call_id]}` — `on_approval_timeout: :fail`.
    * `{:persist_failed, reason}` — the session store rejected a write.
    * Core failures such as `{:task_down, reason}` or `{:unexpected_event, ...}`.

  ## Interrupted tool calls

  A turn that fails or is killed after the assistant's `tool_use` was appended leaves
  it unanswered. The next turn appends an `interrupted: true` tool result for each
  missing call, in memory and store, before the user message, and logs a warning.
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
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ToolCall
  alias Normandy.Telemetry.Metadata
  alias Normandy.Telemetry.OtelCtx

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

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    validate_on_approval_timeout!(Keyword.get(opts, :on_approval_timeout, :continue))

    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end

  @doc """
  Run a turn synchronously; replies once the turn finalizes or fails.

  The caller's OpenTelemetry context travels with the request, so the turn's run
  span nests under the caller's active span (a no-op without OTel).
  """
  @spec run(:gen_statem.server_ref(), term()) :: {:ok, term()} | {:error, term()}
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
    store = Keyword.fetch!(opts, :store)
    session_id = Keyword.fetch!(opts, :session_id)

    register_self(%Data{registry: Keyword.fetch!(opts, :registry), session_id: session_id})

    # The store is the only source of durable state, on a first start and on a
    # supervisor restart alike: the start arguments are captured once and would
    # bring back the memory and turn state of the first start. Starting without
    # the saved turn would drop it, and failing the start would make the
    # supervisor retry at once, spending the restart limit every session shares.
    # So a store fault starts the server :unavailable, retrying the load.
    case load_session(opts, store, session_id) do
      {:ok, config, template, turn_state} ->
        init_data(opts, config, template, turn_state)

      {:error, reason} ->
        unavailable(opts, reason)
    end
  end

  defp load_session(opts, store, session_id) do
    with {:ok, config, template} <- start_config(opts, store, session_id),
         {:ok, config} <- with_stored_memory(config, store, session_id),
         {:ok, turn_state} <- load_turn_state(store, session_id) do
      {:ok, config, template, turn_state}
    end
  end

  defp unavailable(opts, reason) do
    session_id = Keyword.fetch!(opts, :session_id)

    Logger.warning(
      "Turn.Server could not load session #{inspect(session_id)} from the store " <>
        "(#{inspect(reason)}); retrying"
    )

    data = %Data{
      session_id: session_id,
      store: Keyword.fetch!(opts, :store),
      registry: Keyword.fetch!(opts, :registry),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 60_000),
      start_opts: opts,
      retry_ms: @retry_initial_ms
    }

    {:ok, :unavailable, data,
     [{{:timeout, :retry}, @retry_initial_ms, :retry}, idle_timeout(data)]}
  end

  # Loads the session again. On success the transition is the one init/1 would
  # have made; the retry timer is cancelled.
  defp retry_load(%Data{start_opts: opts}) do
    store = Keyword.fetch!(opts, :store)
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, config, template, turn_state} <- load_session(opts, store, session_id) do
      {:ok, :idle, data, actions} = init_data(opts, config, template, turn_state)
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

        with {:ok, tmpl} <- load_config_template(store, template_provider, session_id),
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
      handlers: Keyword.get(opts, :handlers) || BaseAgent.non_streaming_handlers(),
      turn_state: turn_state,
      approval_timeout_ms: timeouts.approval_timeout_ms,
      on_approval_timeout: timeouts.on_approval_timeout,
      idle_timeout_ms: timeouts.idle_timeout_ms
    }

    if data.resume_policy == :eager and resumable?(data.turn_state) do
      {:ok, :idle, data, [{:next_event, :internal, :resume}]}
    else
      {:ok, :idle, data, idle_timeout(data)}
    end
  end

  # No :config AND no :template_provider — a Tier-2 thin start can't reconstruct.
  defp load_config_template(_store, nil, session_id) do
    raise ArgumentError,
          "Turn.Server: session #{inspect(session_id)} was started with neither :config " <>
            "nor :template_provider. A Tier-2 (Horde) thin start requires :template_provider " <>
            "so the server can reconstruct config from the persisted template."
  end

  defp load_config_template({mod, handle}, _template_provider, session_id) do
    case mod.load_config_template(handle, session_id) do
      {:ok, tmpl} -> {:ok, tmpl}
      :error -> {:error, {:no_config_template, session_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A missing supplement or a failed credential lookup is reported like a store
  # fault, so the server waits :unavailable and retries instead of crashing into a
  # supervisor restart loop. Tier-2 reconstruction needs a node-local credential
  # provider (env/vault); CredentialProvider.FromClient has no client here.
  defp reconstruct_config(tmpl, {tp_mod, tp_handle}) do
    template_id = session_id_template_id(tmpl)
    {cred_mod, cred_opts} = tmpl.behaviours_refs.credential

    with {:supplement, {:ok, supplement}} <- {:supplement, tp_mod.fetch(tp_handle, template_id)},
         {:token, {:ok, token}} <- {:token, cred_mod.get_token(token_provider(tmpl), cred_opts)} do
      {:ok, ConfigTemplate.rebuild(tmpl, supplement, token)}
    else
      {:supplement, :error} -> {:error, {:no_template_supplement, template_id}}
      {:token, {:error, reason}} -> {:error, {:credential_unavailable, cred_mod, reason}}
    end
  end

  # Rebuild the conversation from the store's history, keeping the configured
  # memory cap (from_entries/1 builds an uncapped memory).
  defp with_stored_memory(nil, _store, _session_id), do: {:ok, nil}

  defp with_stored_memory(config, {mod, handle}, session_id) do
    case mod.history(handle, session_id) do
      {:ok, entries} ->
        max_messages = config.memory && config.memory.max_messages

        {:ok,
         %{config | memory: %{AgentMemory.from_entries(entries) | max_messages: max_messages}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_turn_state({mod, handle}, sid) do
    case mod.load_turn_state(handle, sid) do
      {:ok, ts} -> {:ok, ts}
      :error -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

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
        {:keep_state_and_data, [{:reply, from, {:error, reason}}, idle_timeout(data)]}
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
            "the store is unavailable (#{inspect(reason)})"
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

    with {:ok, repairs} <- close_batch(data, missing),
         {:ok, config} <- admit(last_config(repairs, data.config), user_input) do
      start_turn(from, {user_input, caller_ctx}, config, repairs, data)
    else
      {:rejected, exception} ->
        emit_rejected_run(data, caller_ctx, exception)
        {:keep_state, data, [{:reply, from, {:error, {:rejected, exception}}}]}

      {:crashed, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
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

  # A monitored Task crashed: feed the matching *_error event into the core.
  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        :running,
        %Data{task_ref: ref} = data
      ) do
    event =
      case data.task_kind do
        :tools -> {:tool_error, {:task_down, reason}}
        _llm_or_compact -> {:llm_error, {:task_down, reason}}
      end

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

    {state, effects} = Turn.step(data.turn_state, {:approval, decisions})
    interpret(effects, %{data | turn_state: state})
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

    {state, effects} =
      Turn.step(data.turn_state, {:approval_expired, %{mode: mode, timeout_ms: ms}})

    interpret(effects, %{data | turn_state: state})
  end

  # Idle long enough → passivate. Final turn state is already persisted; just stop.
  # An :unavailable server nobody calls stops too; the next caller starts it again.
  def handle_event(:state_timeout, :passivate, state, data)
      when state in [:idle, :unavailable] do
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

    stop_run_span(data, :exception, %{kind: :exit, reason: reason, stacktrace: []})
  end

  defp validate_on_approval_timeout!(mode) when mode in [:continue, :fail], do: :ok

  defp validate_on_approval_timeout!(other) do
    raise ArgumentError,
          "Turn.Server.start_link/1: invalid :on_approval_timeout, expected :continue or :fail, " <>
            "got: #{inspect(other)}"
  end

  # Schema and input-guardrail rejections are expected outcomes: reply them as data
  # without touching state. Anything else admit_turn_input raises is a bug and crashes.
  defp admit(config, user_input) do
    {:ok, BaseAgent.admit_turn_input(config, user_input)}
  rescue
    e in [Normandy.Schema.ValidationError, Normandy.Guardrails.ViolationError] ->
      {:rejected, e}
  end

  # Store order mirrors memory order: interrupted results, then the user message.
  # Memory must end up holding exactly what reached the store: a failed write keeps
  # the config as of the last stored result, so the next turn repairs only the rest.
  defp start_turn(from, {user_input, caller_ctx}, config, repairs, data) do
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
        {:keep_state, %{data | config: stored}, [{:reply, from, persist_failed(reason)}]}
    end
  end

  defp persist_failed(reason), do: {:error, {:persist_failed, reason}}

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
  # that ends in :exception; do the same here (the reply is unchanged). The turn id
  # is left out: admission raised before a turn was initialised.
  defp emit_rejected_run(data, caller_ctx, exception) do
    span = start_run_span(data, data.config, caller_ctx, nil)

    stop_run_span(%{data | run_span: span, approval_wait: 0}, :exception, %{
      kind: :error,
      reason: {:rejected, exception},
      stacktrace: []
    })
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
  # crashing append replies instead of going through fail/2). Returns one
  # {call, result, config_after_this_result} per missing call.
  defp close_batch(_data, []), do: {:ok, []}

  defp close_batch(data, missing) do
    call_handler(data, :append, fn ->
      {repairs, _config} =
        Enum.map_reduce(missing, data.config, fn call, config ->
          result = interrupted_result(call)
          folded = data.handlers.append.(config, "tool", result)
          {{call, result, folded}, folded}
        end)

      repairs
    end)
  end

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
    %Normandy.Components.ToolResult{
      tool_call_id: Map.get(call, :id),
      output: %{
        error:
          "tool call interrupted: the previous turn ended before a result was recorded; " <>
            "the tool may or may not have run",
        interrupted: true
      },
      is_error: true
    }
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
        guarded(
          data,
          :convert,
          fn -> data.handlers.convert.(data.config, raw, schema) end,
          &advance(rest, data, {:output_converted, &1})
        )

      {:validate_output, value} ->
        guarded(
          data,
          :validate,
          fn -> data.handlers.validate.(data.config, value) end,
          &advance(rest, data, {:output_validated, &1})
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
        spawn_task(data, :llm, fn h, d ->
          {:llm_response, h.call_llm.(d.config, d.turn_state, request)}
        end)

      {:dispatch_tools, calls} ->
        spawn_task(data, :tools, fn _h, d -> dispatch(d, calls) end)

      {:execute_approved, calls} ->
        spawn_task(data, :tools, fn _h, d ->
          {:approved_results, execute_approved(d, calls)}
        end)

      {:maybe_compact, info} ->
        spawn_task(data, :compact, fn h, d ->
          {config2, meta} = h.compact.(d.config, d.turn_state, info)
          {:compact_result, config2, meta}
        end)

      {:finalize, value} ->
        # Persist the terminal (:stopped) turn state so the resume reaper can tell a
        # completed session from a mid-turn one. Best-effort: the turn already
        # succeeded, so a failed marker-persist must not fail it.
        _ = persist_turn_state(data, data.turn_state)
        stop_run_span(data, :stop, %{})
        reply(data, {:ok, value})
        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil}, idle_timeout(data)}

      {:fail, reason} ->
        # Persist the terminal (:failed) turn state (best-effort) for the same reason.
        _ = persist_turn_state(data, data.turn_state)
        stop_run_span(data, :exception, %{kind: :error, reason: reason, stacktrace: []})
        reply(data, {:error, reason})
        {:next_state, :idle, %{data | pending_reply: nil, run_span: nil}, idle_timeout(data)}
    end
  end

  # `advance` feeds an in-line (non-blocking) result back into the core and keeps
  # interpreting — convert/validate/guard never leave the current handler.
  defp advance(rest, data, event) do
    {state, effects} = Turn.step(data.turn_state, event)
    interpret(effects ++ rest, %{data | turn_state: state})
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
          fun.(handlers, current)
        end)
      end)

    ref = Process.monitor(pid)
    send(pid, {:monitor_ref, ref})
    {:next_state, :running, %{data | task_ref: ref, task_kind: kind}}
  end

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
          describe_crash(kind, reason, __STACKTRACE__)
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
    kind, reason ->
      stacktrace = __STACKTRACE__

      Logger.error(
        "Turn.Server handler #{inspect(name)} crashed (session #{inspect(data.session_id)}): " <>
          describe_crash(kind, reason, stacktrace) <>
          "\n" <> Exception.format_stacktrace(arity_only(stacktrace))
      )

      {:crashed, {:handler_crashed, name, Exception.normalize(kind, reason, stacktrace)}}
  end

  defp guard_output(data, value) do
    data.handlers.guard.(data.config, value)
  rescue
    e in Normandy.Guardrails.ViolationError -> {:output_rejected, e}
  end

  defp guarded(data, name, fun, continue) do
    case call_handler(data, name, fun) do
      {:ok, value} -> continue.(value)
      {:crashed, reason} -> fail(data, reason)
    end
  end

  # Log text must never carry handler values. Handlers receive and return the config
  # (client credentials, req_options), and Exception.message/1 of a MatchError,
  # CaseClauseError, BadMapError, WithClauseError or an ErlangError embeds the offending
  # value; so do exit terms like {:timeout, {GenServer, :call, [pid, msg, t]}}. Only
  # RuntimeError and ArgumentError messages (author-written strings) are logged; for
  # anything else, the kind, struct name or tag, never the payload. The reply to the
  # caller keeps the full term.
  defp describe_crash(kind, reason, stacktrace) do
    case Exception.normalize(kind, reason, stacktrace) do
      %mod{} = e when kind == :error and mod in [RuntimeError, ArgumentError] ->
        "error #{inspect(mod)}: " <> Exception.message(e)

      %mod{} when kind == :error ->
        "error #{inspect(mod)}"

      term ->
        "#{kind} " <> describe_term(term)
    end
  end

  defp describe_term(term) when is_atom(term), do: inspect(term)

  defp describe_term(term)
       when is_tuple(term) and tuple_size(term) > 0 and is_atom(elem(term, 0)),
       do: "{#{inspect(elem(term, 0))}, ...}"

  defp describe_term(term) when is_tuple(term), do: "a tuple"
  defp describe_term(term) when is_map(term), do: "a map"
  defp describe_term(term) when is_list(term), do: "a list"
  defp describe_term(term) when is_binary(term), do: "a binary"
  defp describe_term(_term), do: "a term"

  # Stack frames can carry call arguments (a FunctionClauseError's top frame does),
  # and an argument may be the config, which can hold credentials. Log arities only.
  defp arity_only(stacktrace) do
    Enum.map(stacktrace, fn
      {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
      frame -> frame
    end)
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

  defp persist_turn_state(%Data{store: {mod, handle}, session_id: sid}, turn_state),
    do: mod.save_turn_state(handle, sid, turn_state)

  # The entry carries the turn id the memory gave this message, so a memory rebuilt from
  # the store keeps the turn boundaries, and the entry id the memory gave it, so a
  # rehydrated memory has the ids the live one had (after_compact hooks deduplicate on
  # them).
  defp append_to_store(%Data{store: {mod, handle}, session_id: sid}, config, role, content, id) do
    case mod.append_entry(handle, sid, %Normandy.Components.AgentMemory.Entry{
           id: id,
           turn_id: current_turn_id(config),
           role: role,
           content: content
         }) do
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

    runnable = for {_call, {:execute, prepared, ncall}} <- classified, do: {prepared, ncall}
    denied = for {_call, {:deny, %_{} = result}} <- classified, do: result

    executed =
      runnable
      |> Task.async_stream(
        fn {prepared, ncall} ->
          OtelCtx.restore(parent_ctx)
          Dispatch.execute(config, prepared, ncall, pipeline)
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

  # Run already-approved calls: re-derive `prepared` (registry + prepare_tool,
  # deterministic, no policy) and run Dispatch.execute/4. NOT re-classify —
  # re-running policy would re-park. Concurrency mirrors dispatch/2.
  defp execute_approved(%Data{config: config}, calls) do
    pipeline = BaseAgent.base_agent_pipeline(config)
    max_conc = max(config.max_tool_concurrency || 1, 1)
    parent_ctx = OtelCtx.capture()

    calls
    |> Task.async_stream(
      fn %ToolCall{} = call ->
        OtelCtx.restore(parent_ctx)
        {:ok, tool} = Normandy.Tools.Registry.get(config.tool_registry, call.name)
        prepared = Dispatch.prepare_tool(tool, call.input)
        Dispatch.execute(config, prepared, call, pipeline)
      end,
      ordered: true,
      max_concurrency: max_conc,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Enum.map(&BaseAgent.unwrap_tool_task_result!/1)
  end
end
