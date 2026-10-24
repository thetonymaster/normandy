defmodule Normandy.Coordination.AgentProcess.Engine.Server do
  @moduledoc false
  # `turn_engine: :server`. Turns go through the durable `Turn.Session`/`Turn.Server`
  # engine: an admitted run or cast starts its worker at once (Turn.Server serializes the
  # turns), and the SessionStore owns the conversation memory.
  # engine_state: `%{session: Turn.Session.t(), pending_runs: %{worker_pid => running}}`.

  @behaviour Normandy.Coordination.AgentProcess.Engine

  require Logger

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Coordination.AgentProcess.Engine
  alias Normandy.Coordination.AgentProcess.ScopedRegistry
  alias Normandy.Coordination.Orchestration
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.TurnError
  alias Normandy.WatchedWorker

  # The session keys init/3 passes on untouched: all of Session's but the ones it builds
  # itself (the id, the config and the infra it may start and own).
  @session_options Turn.Session.Options.types()
                   |> Map.keys()
                   |> Kernel.--([:session_id, :config, :store, :registry, :supervisor])

  @impl true
  def init(opts, agent, agent_id) do
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

        {:ok, %{session: session, pending_runs: %{}}, owned}

      {:error, _reason} = error ->
        error
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

    # Without a :registry, a scope in Normandy's shared registry: nothing to start or own.
    registry = Keyword.get_lazy(opts, :registry, fn -> {ScopedRegistry, ScopedRegistry.new()} end)

    {supervisor, owned_sup} =
      case Keyword.get(opts, :supervisor) do
        nil ->
          {:ok, sup} = Turn.Supervisor.start_link([])
          {sup, [sup]}

        supplied ->
          {supplied, []}
      end

    {:ok, store, registry, supervisor, owned_store ++ owned_sup}
  rescue
    e -> {:error, e}
  end

  @impl true
  def admit({_kind, _to, input, otel_ctx} = op, state) do
    session = state.engine_state.session
    who = Engine.who(op, state.agent_id)

    {pid, ref} =
      WatchedWorker.start(:server_result, fn ->
        OtelCtx.restore(otel_ctx)
        turn(session, Orchestration.prepare_input(input), who)
      end)

    running = %{ref: ref, op: op, started: System.monotonic_time(:millisecond)}
    put_pending(state, &Map.put(&1, pid, running))
  end

  # Store-authoritative read: rebuild config.memory from the SessionStore so callers
  # see durable truth. On a store fault, or a history from_entries/1 refuses (a snapshot
  # version a newer node wrote, content that cannot be encoded), log and return the
  # template unchanged: a stored history must not crash this process and its queue.
  @impl true
  def get_agent(%{
        engine_state: %{session: %Turn.Session{store: {mod, handle}}},
        agent: agent,
        agent_id: sid
      }) do
    case SessionStore.restore_history(mod, handle, sid) do
      {:ok, entries} ->
        rebuild_memory(agent, sid, entries)

      {:error, reason} ->
        Logger.warning(
          "AgentProcess #{sid}: get_agent could not read store: #{Describe.reason_tag(reason)}"
        )

        agent
    end
  end

  defp rebuild_memory(agent, sid, entries) do
    rebuilt = %{AgentMemory.from_entries(entries) | max_messages: agent.memory.max_messages}
    %{agent | memory: rebuilt}
  rescue
    # The message names entry ids and types only (from_entries/1), never content.
    e in ArgumentError ->
      Logger.warning(
        "AgentProcess #{sid}: get_agent could not rebuild the stored history: " <>
          Exception.message(e)
      )

      agent
  end

  @impl true
  def update_agent(update_fn, _from, state) do
    {reply, state} = Engine.update_agent_now(update_fn, state, &put_agent/2)
    {:reply, reply, state}
  end

  # In :server mode the SessionStore owns the memory, so a changed memory is ignored; the
  # session's next server start uses the new config. A config the session refuses
  # (Turn.Session.put_config/2 raises ArgumentError, e.g. a template-backed session whose
  # new config has no credential provider) is replied as {:error, exception}; the process
  # keeps its config.
  defp put_agent(updated, state) do
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

    case put_session_config(state.engine_state.session, new_agent) do
      {:ok, session} ->
        {:ok, %{state | agent: new_agent, engine_state: %{state.engine_state | session: session}}}

      {:error, _exception} = error ->
        {error, state}
    end
  end

  defp put_session_config(session, config) do
    {:ok, Turn.Session.put_config(session, config)}
  rescue
    e in ArgumentError -> {:error, e}
  end

  @impl true
  def approve(decisions, state), do: Turn.Session.approve(state.engine_state.session, decisions)

  # A turn finished (or its worker died).
  @impl true
  def handle_info({:server_result, pid, result}, state) do
    case Map.pop(state.engine_state.pending_runs, pid) do
      {nil, _pending} ->
        {:noreply, state}

      {running, pending_runs} ->
        Process.demonitor(running.ref, [:flush])

        {:noreply,
         state |> put_pending(fn _ -> pending_runs end) |> Engine.finish_op(running, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.engine_state.pending_runs, pid) do
      {%{ref: ^ref} = running, pending_runs} ->
        {:noreply,
         state
         |> put_pending(fn _ -> pending_runs end)
         |> Engine.finish_op(running, Engine.worker_down(reason))}

      _not_a_worker ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, _state), do: :unhandled

  @impl true
  def load(%{engine_state: %{pending_runs: pending_runs}}),
    do: %{queued: 0, in_flight: map_size(pending_runs)}

  defp put_pending(state, fun),
    do: %{
      state
      | engine_state: %{state.engine_state | pending_runs: fun.(state.engine_state.pending_runs)}
    }

  # One turn, in the worker: the Turn.Session reply, or any raise, exit or throw logged
  # (arities only) and turned into the reply a worker dying of it would give (a domain
  # exception bare, anything else a :task_down TurnError). Not Orchestration.classify/2,
  # which returns any raise bare.
  defp turn(session, user_input, who) do
    case Turn.Session.run(session, user_input) do
      {:ok, value} -> {:ok, Engine.extract_result(value)}
      {:error, _} = error -> error
    end
  catch
    kind, reason ->
      Logger.error("#{who} raised " <> TurnError.format_raised(kind, reason, __STACKTRACE__))
      Engine.worker_down(exit_reason(kind, reason))
  end

  # The exit reason a process dies with for a caught kind and reason, so a failure caught
  # in a worker maps like the same failure arriving as its :DOWN.
  defp exit_reason(:error, reason), do: Exception.normalize(:error, reason)
  defp exit_reason(:throw, value), do: {:nocatch, value}
  defp exit_reason(:exit, reason), do: reason
end
