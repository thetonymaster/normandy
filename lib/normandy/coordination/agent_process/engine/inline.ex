defmodule Normandy.Coordination.AgentProcess.Engine.Inline do
  @moduledoc false
  # `turn_engine: :inline`. Runs, casts and agent updates go through one FIFO queue and
  # execute one at a time; each turn runs in a worker (`WatchedWorker`) started from the
  # config the previous turn left, so the process itself never waits on a turn.
  # engine_state: `%{running: %{pid, ref, op, started} | nil, queue: :queue.queue()}`.

  @behaviour Normandy.Coordination.AgentProcess.Engine

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.AgentProcess.Engine
  alias Normandy.Coordination.Orchestration
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.WatchedWorker

  @impl true
  def init(_opts, _agent, _agent_id), do: {:ok, %{running: nil, queue: :queue.new()}, []}

  @impl true
  def admit(op, state), do: enqueue(op, state)

  @impl true
  def get_agent(state), do: state.agent

  # Queued like a run, so an update sees the memory of every run before it and no run in
  # flight overwrites it.
  @impl true
  def update_agent(update_fn, from, state),
    do: {:noreply, enqueue({:update, from, update_fn}, state)}

  @impl true
  def approve(_decisions, _state), do: {:error, :inline_mode}

  # The turn in flight finished (or its worker died); start the next op.
  @impl true
  def handle_info(
        {:inline_result, pid, result},
        %{engine_state: %{running: %{pid: pid} = running}} = state
      ) do
    Process.demonitor(running.ref, [:flush])
    {:noreply, state |> finish(running, result) |> dispatch()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{engine_state: %{running: %{ref: ref} = running}} = state
      ) do
    {:noreply, state |> finish(running, Engine.worker_down(reason)) |> dispatch()}
  end

  def handle_info(_msg, _state), do: :unhandled

  @impl true
  def load(%{engine_state: %{queue: queue, running: running}}),
    do: %{queued: :queue.len(queue), in_flight: if(running, do: 1, else: 0)}

  defp finish(state, running, result) do
    state
    |> put_engine(%{running: nil})
    |> Engine.finish_op(running, result)
  end

  # ops run one at a time, oldest first: runs, casts and {:update, from, update_fn}.
  defp enqueue(op, state) do
    queue = :queue.in(op, state.engine_state.queue)
    dispatch(put_engine(state, %{queue: queue}))
  end

  # Starts queued ops while no turn is in flight: an update applies at once, a run
  # starts a worker (and dispatching stops until it finishes).
  defp dispatch(%{engine_state: %{running: nil, queue: queue}} = state) do
    case :queue.out(queue) do
      {:empty, _queue} -> state
      {{:value, op}, queue} -> dispatch(start_op(op, put_engine(state, %{queue: queue})))
    end
  end

  defp dispatch(state), do: state

  defp start_op({:update, from, update_fn}, state) do
    {reply, state} = Engine.update_agent_now(update_fn, state, &put_agent/2)
    GenServer.reply(from, reply)
    state
  end

  defp start_op({:run, from, input, otel_ctx} = op, state) do
    if caller_alive?(from),
      do: start_turn(op, input, otel_ctx, state),
      else: %{state | pending: state.pending - 1}
  end

  defp start_op({:cast, _reply_to, input, otel_ctx} = op, state),
    do: start_turn(op, input, otel_ctx, state)

  defp put_agent(updated, state), do: {:ok, %{state | agent: updated}}

  # The worker gets the committed config, the input and the caller's OTel context, not
  # the process state.
  defp start_turn(op, input, otel_ctx, state) do
    agent = state.agent
    who = Engine.who(op, state.agent_id)

    {pid, ref} =
      WatchedWorker.start(:inline_result, fn ->
        OtelCtx.restore(otel_ctx)
        turn(agent, input, who)
      end)

    running = %{pid: pid, ref: ref, op: op, started: System.monotonic_time(:millisecond)}
    put_engine(state, %{running: running})
  end

  # A caller that died while its run waited (a Reactive task killed past its timeout)
  # gets no turn. Only a local pid can be checked; a remote caller's run always starts.
  defp caller_alive?({pid, _tag}) when node(pid) == node(), do: Process.alive?(pid)
  defp caller_alive?(_from), do: true

  # One turn, in the worker, classified by `Orchestration.classify/2`: a Normandy error is
  # returned; a raise (a bug) is logged (arities only) and returned bare; an exit or a
  # throw is logged and becomes the :task_down TurnError a worker dying of it would give.
  defp turn(agent, input, who) do
    Orchestration.classify(who, fn ->
      case BaseAgent.run(agent, Orchestration.prepare_input(input)) do
        {:ok, updated_agent, response} -> {:ok, updated_agent, Engine.extract_result(response)}
        {:error, exception} -> {:error, exception}
      end
    end)
  end

  defp put_engine(state, changes),
    do: %{state | engine_state: Map.merge(state.engine_state, changes)}
end
