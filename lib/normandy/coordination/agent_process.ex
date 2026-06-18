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
    that terminate with it. `:subscriber`, `:handlers`, `:approval_timeout_ms`,
    and `:idle_timeout_ms` are forwarded to `Turn.Session` when supplied.
  """

  use GenServer
  require Logger

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn

  @type agent_id :: String.t()
  @type run_opts :: [
          timeout: non_neg_integer(),
          async: boolean(),
          reply_to: pid()
        ]

  # Client API

  @doc """
  Starts an AgentProcess GenServer.

  ## Options

  - `:agent` - BaseAgent struct (required)
  - `:name` - Register the process with a name (optional)
  - `:agent_id` - Unique identifier for this agent (default: UUID)
  - `:context_pid` - StatefulContext process to use (optional)

  ## Example

      {:ok, pid} = AgentProcess.start_link(
        agent: my_agent,
        name: :my_agent,
        agent_id: "agent_1"
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # Validate that :agent key exists (will raise if missing)
    _agent = Keyword.fetch!(opts, :agent)
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Executes the agent synchronously.

  Runs the agent with the given input and returns the result.

  ## Options

  - `:timeout` - Call timeout in ms (default: 60_000)

  ## Example

      {:ok, result} = AgentProcess.run(pid, "What is AI?")
  """
  @spec run(GenServer.server(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(server, input, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(server, {:run, input}, timeout)
  end

  @doc """
  Executes the agent asynchronously.

  The agent runs in the background. If `:reply_to` is provided,
  sends `{:agent_result, agent_id, result}` when complete.

  ## Options

  - `:reply_to` - PID to send result to (optional)

  ## Example

      :ok = AgentProcess.cast(pid, input, reply_to: self())

      receive do
        {:agent_result, agent_id, result} ->
          IO.inspect(result)
      end
  """
  @spec cast(GenServer.server(), term(), keyword()) :: :ok
  def cast(server, input, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to)
    GenServer.cast(server, {:run_async, input, reply_to})
  end

  @doc """
  Delivers approval decisions to a turn parked awaiting human approval
  (`:server` mode only). `decisions` maps `tool_call_id` to `:approve | :reject`;
  any parked id absent or `:reject` is treated as rejected (fail-closed).

  Returns `:ok`, `{:error, :no_session}` if no live parked session exists, or
  `{:error, :inline_mode}` when the process runs in `:inline` mode.
  """
  @spec approve(GenServer.server(), %{optional(String.t()) => :approve | :reject}) ::
          :ok | {:error, :no_session} | {:error, :inline_mode}
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
  Updates the agent state.

  Useful for modifying configuration or resetting state.

  ## Example

      :ok = AgentProcess.update_agent(pid, fn agent ->
        %{agent | config: new_config}
      end)
  """
  @spec update_agent(GenServer.server(), (struct() -> struct())) :: :ok
  def update_agent(server, update_fn) do
    GenServer.call(server, {:update_agent, update_fn})
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
    agent_id = Keyword.get(opts, :agent_id, UUID.uuid4())
    context_pid = Keyword.get(opts, :context_pid)
    turn_engine = Keyword.get(opts, :turn_engine, :inline)

    base = %{
      agent: agent,
      agent_id: agent_id,
      context_pid: context_pid,
      turn_engine: turn_engine,
      store: nil,
      registry: nil,
      supervisor: nil,
      supervisor_mod: Keyword.get(opts, :supervisor_mod, Normandy.Agents.Turn.Supervisor),
      template_provider: Keyword.get(opts, :template_provider),
      resume_policy: Keyword.get(opts, :resume_policy, :lazy),
      template_id: Keyword.get(opts, :template_id),
      extra_session_opts: [],
      owned: [],
      pending_runs: %{},
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
            {:ok,
             %{
               base
               | store: store,
                 registry: registry,
                 supervisor: supervisor,
                 owned: owned,
                 extra_session_opts:
                   Keyword.take(opts, [
                     :subscriber,
                     :handlers,
                     :approval_timeout_ms,
                     :idle_timeout_ms
                   ])
             }}

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
          store_pid = Normandy.Behaviours.SessionStore.InMemory.new()
          {{Normandy.Behaviours.SessionStore.InMemory, store_pid}, [store_pid]}

        supplied ->
          {supplied, []}
      end

    {registry, owned_reg} =
      case Keyword.get(opts, :registry) do
        nil ->
          name = :"agentprocess_reg_#{System.unique_integer([:positive])}"
          {:ok, reg_pid} = Normandy.Behaviours.SessionRegistry.Native.start_link(name: name)
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

  # The keyword list Turn.Session.run/2 and Turn.Session.approve/2 expect.
  # Used by Turn.Server routing (Task 2+).
  defp session_opts(state) do
    [
      session_id: state.agent_id,
      config: state.agent,
      store: state.store,
      registry: state.registry,
      supervisor: state.supervisor,
      supervisor_mod: Map.get(state, :supervisor_mod, Normandy.Agents.Turn.Supervisor),
      template_provider: Map.get(state, :template_provider),
      resume_policy: Map.get(state, :resume_policy, :lazy),
      template_id: Map.get(state, :template_id)
    ] ++ state.extra_session_opts
  end

  @impl true
  def handle_call({:run, input}, from, %{turn_engine: :server} = state) do
    start_time = System.monotonic_time(:millisecond)
    ref = spawn_run(state, prepare_input(input))
    {:noreply, %{state | pending_runs: Map.put(state.pending_runs, ref, {from, start_time})}}
  end

  @impl true
  def handle_call({:run, input}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        # Prepare input
        agent_input = prepare_input(input)

        # Run agent
        {updated_agent, response} = BaseAgent.run(state.agent, agent_input)

        # Extract result
        result = extract_result(response)

        # Update state with new agent
        end_time = System.monotonic_time(:millisecond)
        runtime = end_time - start_time

        updated_state = %{
          state
          | agent: updated_agent,
            run_count: state.run_count + 1,
            last_run: DateTime.utc_now(),
            total_runtime_ms: state.total_runtime_ms + runtime
        }

        {:reply, {:ok, result}, updated_state}
      rescue
        e ->
          Logger.error("Agent #{state.agent_id} failed: #{Exception.message(e)}")
          {:reply, {:error, {:exception, e, __STACKTRACE__}}, state}
      end

    result
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

  @impl true
  def handle_call({:update_agent, update_fn}, _from, %{turn_engine: :server} = state) do
    updated = update_fn.(state.agent)

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

    {:reply, :ok, %{state | agent: new_agent}}
  end

  @impl true
  def handle_call({:update_agent, update_fn}, _from, state) do
    updated_agent = update_fn.(state.agent)
    {:reply, :ok, %{state | agent: updated_agent}}
  end

  @impl true
  def handle_call({:approve, decisions}, _from, %{turn_engine: :server} = state) do
    {:reply, Turn.Session.approve(session_opts(state), decisions), state}
  end

  @impl true
  def handle_call({:approve, _decisions}, _from, state) do
    {:reply, {:error, :inline_mode}, state}
  end

  @impl true
  def handle_cast({:run_async, input, reply_to}, %{turn_engine: :server} = state) do
    opts = session_opts(state)
    agent_id = state.agent_id
    user_input = prepare_input(input)

    Task.start(fn ->
      # Guarantee reply_to always hears back: a raised/exited turn must not be
      # lost silently. Mirrors the inline path's handle_async_run/3 error shape,
      # plus a catch for exits/throws (Turn.Session.run can crash the turn).
      result =
        try do
          case Turn.Session.run(opts, user_input) do
            {:ok, value} -> {:ok, extract_result(value)}
            {:error, _} = err -> err
          end
        rescue
          e ->
            Logger.error("Async agent #{agent_id} failed: #{Exception.message(e)}")
            {:error, {:exception, e, __STACKTRACE__}}
        catch
          kind, reason ->
            Logger.error("Async agent #{agent_id} #{kind}: #{inspect(reason)}")
            {:error, {kind, reason}}
        end

      if reply_to, do: send(reply_to, {:agent_result, agent_id, result})
    end)

    {:noreply, %{state | run_count: state.run_count + 1, last_run: DateTime.utc_now()}}
  end

  @impl true
  def handle_cast({:run_async, input, reply_to}, state) do
    # Spawn task to run agent without blocking GenServer
    {:ok, _task_pid} =
      Task.start(fn ->
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
  defp spawn_run(state, user_input) do
    server = self()
    opts = session_opts(state)

    worker =
      spawn(fn ->
        ref =
          receive do
            {:monitor_ref, r} -> r
          end

        result =
          case Turn.Session.run(opts, user_input) do
            {:ok, value} -> {:ok, extract_result(value)}
            {:error, _} = err -> err
          end

        send(server, {:run_result, ref, result})
      end)

    ref = Process.monitor(worker)
    send(worker, {:monitor_ref, ref})
    ref
  end

  @impl true
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
        GenServer.reply(from, {:error, {:task_down, reason}})
        {:noreply, %{state | pending_runs: rest}}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("AgentProcess #{state.agent_id} ignoring unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

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
    try do
      agent_input = prepare_input(input)
      {_updated_agent, response} = BaseAgent.run(agent, agent_input)
      result = extract_result(response)
      {:ok, result}
    rescue
      e ->
        Logger.error("Async agent #{agent_id} failed: #{Exception.message(e)}")
        {:error, {:exception, e, __STACKTRACE__}}
    end
  end

  # Store-authoritative read: rebuild config.memory from the SessionStore so callers
  # see durable truth. On a store fault, log and return the template unchanged.
  defp reconstruct_agent(%{store: {mod, handle}, agent: agent, agent_id: sid}) do
    case mod.history(handle, sid) do
      {:ok, entries} ->
        rebuilt = %{
          Normandy.Components.AgentMemory.from_entries(entries)
          | max_messages: agent.memory.max_messages
        }

        %{agent | memory: rebuilt}

      {:error, reason} ->
        Logger.warning("AgentProcess #{sid}: get_agent could not read store: #{inspect(reason)}")
        agent
    end
  end
end
