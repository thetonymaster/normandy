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

  alias Normandy.Agents.{BaseAgent, Turn}

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
              idle_timeout_ms: 60_000
  end

  # ---- public API ----

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

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
    data = %Data{
      session_id: Keyword.fetch!(opts, :session_id),
      config: Keyword.fetch!(opts, :config),
      store: Keyword.fetch!(opts, :store),
      registry: Keyword.fetch!(opts, :registry),
      subscriber: Keyword.get(opts, :subscriber),
      handlers: Keyword.get(opts, :handlers) || BaseAgent.non_streaming_handlers(),
      turn_state: Keyword.get(opts, :turn_state),
      approval_timeout_ms: Keyword.get(opts, :approval_timeout_ms, 300_000),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 60_000)
    }

    register_self(data)
    {:ok, :idle, data, idle_timeout(data)}
  end

  # :idle — accept a new turn request (mid-turn requests are postponed; Task 7).
  @impl true
  def handle_event({:call, from}, {:turn, user_input}, :idle, data) do
    config = BaseAgent.admit_turn_input(data.config, user_input)
    persist_user_message(data, config, user_input)

    state =
      Turn.new(
        max_iterations: config.max_tool_iterations,
        response_model: BaseAgent.turn_response_model(config),
        output_schema: config.output_schema
      )

    data = %{data | config: config, pending_reply: from}
    {state, effects} = Turn.step(state, :start)
    interpret(effects, %{data | turn_state: state})
  end

  # :running — a monitored Task delivered the outcome of a blocking effect.
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

  # ---- effect interpreter ----
  # Processes effects left-to-right. Non-blocking effects run synchronously and
  # advance the core in-line (convert/validate/guard) or just side-effect
  # (append/emit/persist). A blocking effect spawns a monitored Task and parks in
  # :running. {:finalize}/{:fail} reply and return to :idle.

  defp interpret([], data), do: {:keep_state, data}

  defp interpret([effect | rest], data) do
    case effect do
      {:emit_event, name, meta} ->
        emit(data, name, meta)
        interpret(rest, data)

      {:append_message, role, content} ->
        config = data.handlers.append.(data.config, role, content)
        append_to_store(data, role, content)
        interpret(rest, %{data | config: config})

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

  defp register_self(%Data{registry: {mod, handle}, session_id: sid}),
    do: mod.register(handle, sid, self())

  defp persist_turn_state(%Data{store: {mod, handle}, session_id: sid}, turn_state),
    do: mod.save_turn_state(handle, sid, turn_state)

  defp append_to_store(%Data{store: {mod, handle}, session_id: sid}, role, content) do
    {:ok, _id} =
      mod.append_entry(handle, sid, %Normandy.Components.AgentMemory.Entry{
        turn_id: "live",
        role: role,
        content: content
      })

    :ok
  end

  defp persist_user_message(_data, _config, nil), do: :ok

  defp persist_user_message(data, _config, user_input),
    do: append_to_store(data, "user", user_input)

  # dispatch/2 and execute_approved/2 are implemented in Task 5/6.
  defp dispatch(_data, _calls), do: raise("dispatch/2 lands in Task 5")
  defp execute_approved(_data, _calls), do: raise("execute_approved/2 lands in Task 6")
end
