defmodule Normandy.Coordination.AgentProcess.Engine do
  @moduledoc false
  # What `Normandy.Coordination.AgentProcess` asks of a turn engine, and the helpers both
  # engines share. The process holds the agent, the counters and the pending bound; an
  # engine holds its own state in `state.engine_state` and decides how an admitted run or
  # cast executes. `Engine.Inline` runs turns one at a time in a worker; `Engine.Server`
  # routes them through `Turn.Session`.

  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.TurnError

  require Logger

  @typedoc "The AgentProcess state (a map); the engine owns `:engine_state`."
  @type state :: map()

  @typedoc "An admitted run or cast: `{:run, from, input, otel_ctx}` or `{:cast, reply_to, input, otel_ctx}`."
  @type op :: tuple()

  @doc "Builds the engine's state, plus the infra pids it started and the process must stop."
  @callback init(opts :: keyword(), agent :: BaseAgentConfig.t(), agent_id :: String.t()) ::
              {:ok, engine_state :: term(), owned :: [pid()]} | {:error, term()}

  @doc "Takes an admitted op (`state.pending` already counts it)."
  @callback admit(op(), state()) :: state()

  @callback get_agent(state()) :: BaseAgentConfig.t()

  @callback update_agent((BaseAgentConfig.t() -> term()), GenServer.from(), state()) ::
              {:reply, term(), state()} | {:noreply, state()}

  @callback approve(decisions :: map(), state()) :: term()

  @doc "A message the engine owns, or `:unhandled`."
  @callback handle_info(msg :: term(), state()) :: {:noreply, state()} | :unhandled

  @doc "Ops waiting and turns in flight, for the status shown by observers."
  @callback load(state()) :: %{queued: non_neg_integer(), in_flight: non_neg_integer()}

  @doc "The engine module for a `:turn_engine` option value."
  @spec module(:inline | :server) :: module()
  def module(:inline), do: __MODULE__.Inline
  def module(:server), do: __MODULE__.Server

  @doc "The name a turn's log lines carry."
  @spec who(op(), String.t()) :: String.t()
  def who(op, agent_id) do
    if elem(op, 0) == :run, do: "Agent #{agent_id}", else: "Async agent #{agent_id}"
  end

  @doc """
  Applies `update_fn` to the agent: a result that is not a config is refused here, before
  it replaces the agent (the caller raises, the process keeps its config). The reply names
  only its type (a config holds the client and its credentials). `put_fun.(config, state)`
  stores an accepted config and returns `{reply, state}`: `{:ok, state}`, or
  `{{:error, exception}, state}` when the engine refuses it (the process keeps its config).
  """
  @spec update_agent_now((BaseAgentConfig.t() -> term()), state(), (BaseAgentConfig.t(),
                                                                    state() ->
                                                                      {term(), state()})) ::
          {term(), state()}
  def update_agent_now(update_fn, state, put_fun) do
    case update_fn.(state.agent) do
      %BaseAgentConfig{} = updated -> put_fun.(updated, state)
      other -> {{:not_a_config, Describe.type_of(other)}, state}
    end
  end

  @doc """
  A finished run or cast: an inline turn's config is committed, the result goes to the
  caller or reply_to, and the turn is counted whatever its outcome. The engine clears its
  own in-flight record before calling.
  """
  @spec finish_op(state(), map(), term()) :: state()
  def finish_op(state, running, {:ok, agent, value}),
    do: finish_op(%{state | agent: agent}, running, {:ok, value})

  def finish_op(state, %{op: op, started: started}, result) do
    case op do
      {:run, from, _input, _ctx} -> GenServer.reply(from, result)
      {:cast, reply_to, _input, _ctx} -> notify(reply_to, state.agent_id, result)
    end

    count_run(%{state | pending: state.pending - 1}, started)
  end

  @doc "A cast's result to its `reply_to`, which must not crash the process."
  @spec notify(term(), String.t(), term()) :: :ok | nil
  def notify(nil, _agent_id, _result), do: :ok

  def notify(reply_to, agent_id, result) when is_pid(reply_to) do
    send(reply_to, {:agent_result, agent_id, result})
    :ok
  end

  # A name that is not registered must not crash this process (send/2 raises for it).
  def notify(reply_to, agent_id, result) when is_atom(reply_to) do
    case Process.whereis(reply_to) do
      nil ->
        Logger.warning(
          "AgentProcess #{agent_id}: reply_to #{inspect(reply_to)} is not a registered " <>
            "process; the result is dropped"
        )

      pid ->
        send(pid, {:agent_result, agent_id, result})
    end
  end

  # cast/3 accepts only nil, a pid or an atom, but a raw {:run_async, ...} cast (a node
  # running older code, or code that bypasses cast/3) can carry anything ({name, node},
  # a :via tuple). It must not crash this process with its queue: logged by type only
  # (it can hold a name or data), and the result dropped.
  def notify(reply_to, agent_id, _result) do
    Logger.warning(
      "AgentProcess #{agent_id}: reply_to is #{Describe.type_of(reply_to)}, not a pid or " <>
        "a registered name; the result is dropped"
    )
  end

  @doc "A turn's reply value: its `chat_message`, else the whole response."
  @spec extract_result(term()) :: term()
  def extract_result(response) when is_map(response) do
    Map.get(response, :chat_message) ||
      Map.get(response, "chat_message") ||
      response
  end

  defp count_run(state, started) do
    %{
      state
      | run_count: state.run_count + 1,
        last_run: DateTime.utc_now(),
        total_runtime_ms: state.total_runtime_ms + System.monotonic_time(:millisecond) - started
    }
  end

  @doc "The error a worker that died with `reason` gives."
  @spec worker_down(term()) :: {:error, Exception.t()}
  def worker_down(reason), do: {:error, TurnError.from_reason({:task_down, reason})}
end
