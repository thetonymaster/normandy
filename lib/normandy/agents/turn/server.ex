defmodule Normandy.Agents.Turn.Server do
  @moduledoc """
  Asynchronous `:gen_statem` interpreter of the pure `Turn` FSM — the async analog
  of `Turn.Driver`. Coarse lifecycle states (`:running`, `:awaiting_approval`,
  `:idle`) hang Tasks and `state_timeout`s off the turn; they are NOT a
  re-encoding of the seven `Turn.State` statuses (the core stays the source of
  truth). Blocking effects (`:call_llm`, `:dispatch_tools`, `:execute_approved`)
  run in a monitored Task; non-blocking effects run synchronously in the handler.
  """
  @behaviour :gen_statem

  alias Normandy.Agents.{BaseAgent, Dispatch, Turn}
  alias Normandy.Components.ToolCall

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
              pending_reply: nil,
              approval_timeout_ms: 300_000,
              idle_timeout_ms: 60_000,
              template_provider: nil,
              resume_policy: :lazy
  end

  # ---- public API ----

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end

  @doc "Run a turn synchronously; replies once the turn finalizes or fails."
  @spec run(:gen_statem.server_ref(), term()) :: {:ok, term()} | {:error, term()}
  def run(server, user_input), do: :gen_statem.call(server, {:turn, user_input}, :infinity)

  @doc "Deliver approval decisions to a parked server (Task 6)."
  @spec approve(:gen_statem.server_ref(), %{optional(String.t()) => :approve | :reject}) :: :ok
  def approve(server, decisions), do: :gen_statem.cast(server, {:approval, decisions})

  # ---- :gen_statem callbacks ----

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    registry = Keyword.fetch!(opts, :registry)
    session_id = Keyword.fetch!(opts, :session_id)
    template_provider = Keyword.get(opts, :template_provider)

    config =
      if Keyword.has_key?(opts, :config) do
        Keyword.fetch!(opts, :config)
      else
        reconstruct_config!(store, template_provider, session_id)
      end

    turn_state =
      case Keyword.fetch(opts, :turn_state) do
        {:ok, ts} when not is_nil(ts) -> ts
        _ -> load_turn_state(store, session_id)
      end

    resume_policy =
      case Keyword.get(opts, :config) do
        nil -> template_resume_policy(store, session_id, Keyword.get(opts, :resume_policy, :lazy))
        _ -> Keyword.get(opts, :resume_policy, :lazy)
      end

    data = %Data{
      session_id: session_id,
      config: config,
      store: store,
      registry: registry,
      template_provider: template_provider,
      resume_policy: resume_policy,
      subscriber: Keyword.get(opts, :subscriber),
      handlers: Keyword.get(opts, :handlers) || BaseAgent.non_streaming_handlers(),
      turn_state: turn_state,
      approval_timeout_ms: Keyword.get(opts, :approval_timeout_ms, 300_000),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 60_000)
    }

    register_self(data)

    if data.resume_policy == :eager and resumable?(data.turn_state) do
      {:ok, :idle, data, [{:next_event, :internal, :resume}]}
    else
      {:ok, :idle, data, idle_timeout(data)}
    end
  end

  defp reconstruct_config!({store_mod, store_handle}, {tp_mod, tp_handle}, session_id) do
    {:ok, tmpl} = store_mod.load_config_template(store_handle, session_id)
    {:ok, supplement} = tp_mod.fetch(tp_handle, session_id_template_id(tmpl))
    {cred_mod, cred_opts} = tmpl.behaviours_refs.credential
    {:ok, token} = cred_mod.get_token(token_provider(tmpl), cred_opts)
    config = Normandy.Agents.ConfigTemplate.rebuild(tmpl, supplement, token)

    # The thin spec carries no memory; load the conversation graph from the store
    # so a rehydrated/redistributed Tier-2 session resumes with its history (Tier-0/1
    # does this in Turn.Session; the thin path has no Session to inject it).
    case store_mod.history(store_handle, session_id) do
      {:ok, entries} ->
        memory = %{
          Normandy.Components.AgentMemory.from_entries(entries)
          | max_messages: config.memory.max_messages
        }

        %{config | memory: memory}

      {:error, reason} ->
        # Fail-closed: cannot safely reconstruct without the conversation.
        raise "Turn.Server reconstruct: history load failed for #{session_id}: #{inspect(reason)}"
    end
  end

  defp load_turn_state({mod, handle}, sid) do
    case mod.load_turn_state(handle, sid) do
      {:ok, ts} -> ts
      _ -> nil
    end
  end

  defp template_resume_policy({mod, handle}, sid, default) do
    case mod.load_config_template(handle, sid) do
      {:ok, %{resume_policy: rp}} -> rp
      _ -> default
    end
  end

  defp resumable?(%Turn.State{status: status}) when status not in [:stopped, :failed], do: true
  defp resumable?(_), do: false

  defp session_id_template_id(%{template_id: id}), do: id

  # FromClient needs a client carrying :api_key; env/vault providers ignore the
  # first arg. For reconstruction the token must come from a node-local provider,
  # so we pass a minimal provider map derived from the template's model.
  defp token_provider(%{model: model}), do: %{model: model}

  # :idle — accept a new turn request (mid-turn requests are postponed; Task 7).
  @impl true
  def handle_event({:call, from}, {:turn, user_input}, :idle, data) do
    config = BaseAgent.admit_turn_input(data.config, user_input)

    case persist_user_message(data, config, user_input) do
      :ok ->
        state =
          Turn.new(
            max_iterations: config.max_tool_iterations,
            response_model: BaseAgent.turn_response_model(config),
            output_schema: config.output_schema
          )

        data = %{data | config: config, pending_reply: from}
        {state, effects} = Turn.step(state, :start)
        interpret(effects, %{data | turn_state: state})

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, {:persist_failed, reason}}}]}
    end
  end

  # Eager auto-resume: drive the persisted in-flight turn to completion. No caller
  # is waiting (pending_reply is nil → reply/2 is a no-op), so the turn finalizes
  # silently while persisting at each boundary.
  def handle_event(:internal, :resume, :idle, data) do
    {state, effects} = Turn.resume(data.turn_state)
    interpret(effects, %{data | turn_state: state})
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
    {state, effects} = Turn.step(data.turn_state, {:llm_error, {:task_down, reason}})
    interpret(effects, %{data | turn_state: state, task_ref: nil})
  end

  # :awaiting_approval — out-of-band approval decisions for a parked turn.
  def handle_event(:cast, {:approval, decisions}, :awaiting_approval, data) do
    {state, effects} = Turn.step(data.turn_state, {:approval, decisions})
    interpret(effects, %{data | turn_state: state})
  end

  # A stale/duplicate/late approval cast (double-click, or arriving after the turn
  # already resumed or finalized) lands in a state with no parked calls. Drop it
  # rather than let an unhandled event crash (and transient-restart) the server.
  def handle_event(:cast, {:approval, _decisions}, _state, _data) do
    :keep_state_and_data
  end

  # Approval expiry → all-reject (fail-closed): feed an empty decisions map.
  def handle_event(:state_timeout, :approval_expiry, :awaiting_approval, data) do
    {state, effects} = Turn.step(data.turn_state, {:approval, %{}})
    interpret(effects, %{data | turn_state: state})
  end

  # Idle long enough → passivate. Final turn state is already persisted; just stop.
  def handle_event(:state_timeout, :passivate, :idle, data) do
    {:stop, :normal, data}
  end

  # A turn request mid-turn is postponed and replayed when we re-enter :idle.
  def handle_event({:call, _from}, {:turn, _input}, state, _data)
      when state in [:running, :awaiting_approval] do
    {:keep_state_and_data, :postpone}
  end

  # ---- effect interpreter ----
  # Processes effects left-to-right. Non-blocking effects run synchronously and
  # advance the core in-line (convert/validate/guard) or just side-effect
  # (append/emit/persist). A blocking effect spawns a monitored Task and parks in
  # :running. {:finalize}/{:fail} reply and return to :idle.

  defp interpret([], %Data{turn_state: %Turn.State{status: :awaiting_approval}} = data) do
    {:next_state, :awaiting_approval, data,
     {:state_timeout, data.approval_timeout_ms, :approval_expiry}}
  end

  defp interpret([], data), do: {:keep_state, data}

  defp interpret([effect | rest], data) do
    case effect do
      {:emit_event, name, meta} ->
        emit(data, name, meta)
        interpret(rest, data)

      {:append_message, role, content} ->
        config = data.handlers.append.(data.config, role, content)

        case append_to_store(data, role, content) do
          :ok -> interpret(rest, %{data | config: config})
          {:error, reason} -> fail(%{data | config: config}, {:persist_failed, reason})
        end

      {:persist, turn_state} ->
        case persist_turn_state(data, turn_state) do
          :ok -> interpret(rest, data)
          {:error, reason} -> fail(data, {:persist_failed, reason})
        end

      {:convert_output, raw, schema} ->
        advance(rest, data, {:output_converted, data.handlers.convert.(data.config, raw, schema)})

      {:validate_output, value} ->
        advance(rest, data, {:output_validated, data.handlers.validate.(data.config, value)})

      {:guard_output, value} ->
        data.handlers.guard.(data.config, value)
        advance(rest, data, {:output_guarded, value})

      {:call_llm, request} ->
        spawn_task(data, fn h, d ->
          {:llm_response, h.call_llm.(d.config, d.turn_state, request)}
        end)

      {:dispatch_tools, calls} ->
        spawn_task(data, fn _h, d -> dispatch(d, calls) end)

      {:execute_approved, calls} ->
        spawn_task(data, fn _h, d -> {:approved_results, execute_approved(d, calls)} end)

      {:maybe_compact, info} ->
        spawn_task(data, fn h, d ->
          {config2, meta} = h.compact.(d.config, d.turn_state, info)
          {:compact_result, config2, meta}
        end)

      {:finalize, value} ->
        reply(data, {:ok, value})
        {:next_state, :idle, %{data | pending_reply: nil}, idle_timeout(data)}

      {:fail, reason} ->
        reply(data, {:error, reason})
        {:next_state, :idle, %{data | pending_reply: nil}, idle_timeout(data)}
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
  defp spawn_task(data, fun) do
    server = self()
    handlers = data.handlers
    current = data

    pid =
      spawn(fn ->
        ref =
          receive do
            {:monitor_ref, r} -> r
          end

        send(server, {ref, fun.(handlers, current)})
      end)

    ref = Process.monitor(pid)
    send(pid, {:monitor_ref, ref})
    {:next_state, :running, %{data | task_ref: ref}}
  end

  defp fail(data, reason), do: interpret([{:fail, reason}], data)

  # ---- side-effect helpers ----

  defp emit(%Data{subscriber: nil}, _name, _meta), do: :ok
  defp emit(%Data{subscriber: sub}, name, meta) when is_function(sub, 2), do: sub.(name, meta)

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
    if function_exported?(mod, :child_name, 2),
      do: mod.child_name(handle, sid),
      else: :self_register
  end

  defp persist_turn_state(%Data{store: {mod, handle}, session_id: sid}, turn_state),
    do: mod.save_turn_state(handle, sid, turn_state)

  defp append_to_store(%Data{store: {mod, handle}, session_id: sid}, role, content) do
    case mod.append_entry(handle, sid, %Normandy.Components.AgentMemory.Entry{
           turn_id: "live",
           role: role,
           content: content
         }) do
      {:ok, _id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_user_message(_data, _config, nil), do: :ok

  defp persist_user_message(data, _config, user_input),
    do: append_to_store(data, "user", user_input)

  # Classify every call; execute the allowed ones concurrently (mirrors
  # BaseAgent.dispatch_turn_tools/2's Task.async_stream); collect held results.
  # If any call needs approval, park the batch; else hand back ordered results.
  defp dispatch(%Data{config: config}, calls) do
    pipeline = BaseAgent.base_agent_pipeline(config)
    max_conc = max(config.max_tool_concurrency || 1, 1)
    parent_ctx = Normandy.Telemetry.OtelCtx.capture()

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
          Normandy.Telemetry.OtelCtx.restore(parent_ctx)
          Dispatch.execute(config, prepared, ncall, pipeline)
        end,
        ordered: true,
        max_concurrency: max_conc,
        timeout: :infinity,
        on_timeout: :kill_task
      )
      |> Enum.map(&BaseAgent.unwrap_tool_task_result!/1)

    held = executed ++ denied

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
    parent_ctx = Normandy.Telemetry.OtelCtx.capture()

    calls
    |> Task.async_stream(
      fn %ToolCall{} = call ->
        Normandy.Telemetry.OtelCtx.restore(parent_ctx)
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
