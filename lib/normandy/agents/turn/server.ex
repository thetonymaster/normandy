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
    * `:idle_timeout_ms` — idle time before passivation (default 60_000).

  ## Events (`:subscriber`)

    * `:iteration` — `%{iteration: n, iterations_left: m, final: boolean}` before each
      LLM call; `final: true` marks the forced-final call after the budget is spent.
    * `:steering` — `%{iterations_left: m}` after a tool batch, once its state is saved.
    * `:awaiting_approval` — `%{parked: n, resumed: boolean}` when a batch parks, and
      again (`resumed: true`) when a restarted server resumes a parked turn.
    * `:approval_expired` — `%{expired: n, mode: :continue | :fail}`.

  ## Errors from `run/2`

    * `{:rejected, exception}` — the input failed its schema
      (`Normandy.Schema.ValidationError`) or an input guardrail
      (`Normandy.Guardrails.ViolationError`). Nothing was persisted.
    * `{:handler_crashed, name, exception_or_term}` — a synchronous handler
      (`:append`, `:convert`, `:validate`, `:guard`, `:emit`) raised, exited or threw.
    * `{:approval_timeout, [tool_call_id]}` — `on_approval_timeout: :fail`.
    * `{:persist_failed, reason}` — the session store rejected a write.
    * Core failures such as `{:task_down, reason}` or `{:unexpected_event, ...}`.

  ## Interrupted tool calls

  A turn that fails or is killed after the assistant's `tool_use` was appended leaves
  it unanswered. The next turn appends an `interrupted: true` tool result for each
  missing call, in memory and store, before the user message, and logs a warning.
  If a store write fails part-way, memory keeps only the results the store accepted, so the next turn completes the repair without duplicating any result.
  """
  @behaviour :gen_statem

  alias Normandy.Agents.{BaseAgent, Dispatch, Turn}
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ToolCall
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
              pending_reply: nil,
              approval_timeout_ms: 300_000,
              on_approval_timeout: :continue,
              idle_timeout_ms: 60_000,
              template_provider: nil,
              resume_policy: :lazy
  end

  # ---- public API ----

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    validate_on_approval_timeout!(Keyword.get(opts, :on_approval_timeout, :continue))

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
      on_approval_timeout: Keyword.get(opts, :on_approval_timeout, :continue),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 60_000)
    }

    register_self(data)

    if data.resume_policy == :eager and resumable?(data.turn_state) do
      {:ok, :idle, data, [{:next_event, :internal, :resume}]}
    else
      {:ok, :idle, data, idle_timeout(data)}
    end
  end

  # No :config AND no :template_provider — a Tier-2 thin start can't reconstruct.
  defp reconstruct_config!(_store, nil, session_id) do
    raise ArgumentError,
          "Turn.Server: session #{inspect(session_id)} was started with neither :config " <>
            "nor :template_provider. A Tier-2 (Horde) thin start requires :template_provider " <>
            "so the server can reconstruct config from the persisted template."
  end

  defp reconstruct_config!({store_mod, store_handle}, {tp_mod, tp_handle}, session_id) do
    {:ok, tmpl} = store_mod.load_config_template(store_handle, session_id)
    {:ok, supplement} = tp_mod.fetch(tp_handle, session_id_template_id(tmpl))
    {cred_mod, cred_opts} = tmpl.behaviours_refs.credential

    token =
      case cred_mod.get_token(token_provider(tmpl), cred_opts) do
        {:ok, token} ->
          token

        {:error, reason} ->
          # Tier-2 reconstruction needs a node-local provider (env/vault). The default
          # CredentialProvider.FromClient cannot work here — there is no in-memory client.
          raise "Turn.Server reconstruct: credential resolution failed for #{inspect(session_id)} " <>
                  "via #{inspect(cred_mod)}: #{inspect(reason)}. Tier-2 sessions need a node-local " <>
                  "CredentialProvider (e.g. env/vault), not CredentialProvider.FromClient."
      end

    config = ConfigTemplate.rebuild(tmpl, supplement, token)

    # The thin spec carries no memory; load the conversation graph from the store
    # so a rehydrated/redistributed Tier-2 session resumes with its history (Tier-0/1
    # does this in Turn.Session; the thin path has no Session to inject it).
    case store_mod.history(store_handle, session_id) do
      {:ok, entries} ->
        memory = %{
          AgentMemory.from_entries(entries)
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
    missing = data.config.memory |> AgentMemory.messages() |> Turn.unanswered_tool_calls()

    with {:ok, repairs} <- close_batch(data, missing),
         {:ok, config} <- admit(last_config(repairs, data.config), user_input) do
      start_turn(from, user_input, config, repairs, data)
    else
      {:rejected, exception} ->
        {:keep_state, data, [{:reply, from, {:error, {:rejected, exception}}}]}

      {:crashed, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
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

  # Approval window closed with no decision. The core answers every parked call with
  # an expiry result and either continues or fails the turn (on_approval_timeout).
  def handle_event(:state_timeout, :approval_expiry, :awaiting_approval, data) do
    %Turn.State{parked_calls: parked} = data.turn_state
    mode = data.on_approval_timeout
    ms = data.approval_timeout_ms

    :telemetry.execute(
      [:normandy, :turn, :approval, :expired],
      %{count: length(parked)},
      %{
        session_id: data.session_id,
        mode: mode,
        timeout_ms: ms,
        tool_names: Enum.map(parked, & &1.name)
      }
    )

    {state, effects} =
      Turn.step(data.turn_state, {:approval_expired, %{mode: mode, timeout_ms: ms}})

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
  defp start_turn(from, user_input, config, repairs, data) do
    with {:ok, repaired} <- persist_interrupted(data, repairs),
         :ok <- persist_user_message(data, config, user_input, repaired) do
      state =
        Turn.new(
          max_iterations: config.max_tool_iterations,
          response_model: BaseAgent.turn_response_model(config),
          output_schema: config.output_schema
        )

      data = %{data | config: config, pending_reply: from}
      {state, effects} = Turn.step(state, :start)
      interpret(effects, %{data | turn_state: state})
    else
      {:error, stored, reason} ->
        {:keep_state, %{data | config: stored}, [{:reply, from, persist_failed(reason)}]}
    end
  end

  defp persist_failed(reason), do: {:error, {:persist_failed, reason}}

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
      Enum.reduce_while(repairs, {:ok, data.config}, fn {_call, result, folded}, acc ->
        case append_to_store(data, "tool", result) do
          :ok -> {:cont, {:ok, folded}}
          {:error, reason} -> {:halt, {:error, elem(acc, 1), reason}}
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
            case append_to_store(data, role, content) do
              :ok -> interpret(rest, %{data | config: config})
              {:error, reason} -> fail(%{data | config: config}, {:persist_failed, reason})
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
        guarded(
          data,
          :guard,
          fn -> data.handlers.guard.(data.config, value) end,
          fn _ -> advance(rest, data, {:output_guarded, value}) end
        )

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
        # Persist the terminal (:stopped) turn state so the resume reaper can tell a
        # completed session from a mid-turn one. Best-effort: the turn already
        # succeeded, so a failed marker-persist must not fail it.
        _ = persist_turn_state(data, data.turn_state)
        reply(data, {:ok, value})
        {:next_state, :idle, %{data | pending_reply: nil}, idle_timeout(data)}

      {:fail, reason} ->
        # Persist the terminal (:failed) turn state (best-effort) for the same reason.
        _ = persist_turn_state(data, data.turn_state)
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

  # On failure, carries the repaired config so memory keeps matching the store.
  defp persist_user_message(_data, _config, nil, _repaired), do: :ok

  defp persist_user_message(data, _config, user_input, repaired) do
    with {:error, reason} <- append_to_store(data, "user", user_input),
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
