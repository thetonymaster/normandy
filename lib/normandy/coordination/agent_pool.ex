defmodule Normandy.Coordination.AgentPool do
  @moduledoc """
  Pool manager for agent processes with automatic checkout/checkin.

  Provides efficient pooling of identical agent processes with configurable
  size, overflow handling, and checkout strategies. Built on top of
  AgentSupervisor for fault tolerance.

  ## Features

  - Fixed pool size with configurable overflow
  - Multiple checkout strategies: `:lifo`, `:fifo`
  - Automatic checkin on transaction completion
  - Built-in supervision and fault tolerance
  - Pool statistics and monitoring

  ## Examples

      # Start a pool of 10 agents
      {:ok, pool} = AgentPool.start_link(
        name: :my_pool,
        agent_config: my_agent_config,
        size: 10,
        overflow: 5,
        strategy: :fifo
      )

      # Use transaction for automatic checkout/checkin
      {:ok, result} = AgentPool.transaction(pool, fn agent_pid ->
        AgentProcess.run(agent_pid, input)
      end)

      # Manual checkout/checkin
      {:ok, agent_pid} = AgentPool.checkout(pool)
      result = AgentProcess.run(agent_pid, input)
      :ok = AgentPool.checkin(pool, agent_pid)

      # Get pool statistics
      stats = AgentPool.stats(pool)
      #=> %{size: 10, available: 7, in_use: 3, overflow: 0}
  """

  use GenServer
  require Logger

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.AgentSupervisor

  @type strategy :: :lifo | :fifo
  @type pool_stat :: %{
          size: non_neg_integer(),
          overflow: non_neg_integer(),
          available: non_neg_integer(),
          in_use: non_neg_integer(),
          max_overflow: non_neg_integer()
        }

  defmodule State do
    @moduledoc false
    defstruct [
      :supervisor,
      :agent_config,
      :size,
      :max_overflow,
      :strategy,
      available: [],
      in_use: MapSet.new(),
      overflow_count: 0,
      waiting: :queue.new(),
      monitors: %{}
    ]
  end

  # Client API

  @doc """
  Starts an agent pool.

  ## Options

  - `:name` - Register the pool with a name (required for named access)
  - `:agent_config` - BaseAgent configuration map (required)
  - `:size` - Pool size (default: 10)
  - `:max_overflow` - Maximum overflow workers (default: 5)
  - `:strategy` - Checkout strategy `:lifo` or `:fifo` (default: `:lifo`)

  ## Examples

      {:ok, pool} = AgentPool.start_link(
        name: :research_pool,
        agent_config: %{
          client: client,
          model: "claude-3-5-sonnet-20241022",
          temperature: 0.7
        },
        size: 10,
        max_overflow: 5,
        strategy: :fifo
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Executes a function with an agent from the pool.

  Automatically checks out an agent, executes the function, and checks it back in.
  Handles errors gracefully and ensures the agent is always returned to the pool.

  ## Options

  - `:timeout` - Checkout timeout in ms (default: 5000)

  ## Examples

      {:ok, result} = AgentPool.transaction(pool, fn agent_pid ->
        AgentProcess.run(agent_pid, "Analyze this data")
      end)

      # With timeout
      {:ok, result} = AgentPool.transaction(pool, [timeout: 10_000], fn agent_pid ->
        AgentProcess.run(agent_pid, input)
      end)

  ## Returns

  - `{:ok, result}` - Function result
  - `{:error, :timeout}` - Checkout timeout
  - `{:error, :pool_exhausted}` - No agents available and max overflow reached
  - `{:error, reason}` - Function raised an error
  """
  @spec transaction(GenServer.server(), keyword(), (pid() -> term())) ::
          {:ok, term()} | {:error, term()}
  def transaction(pool, opts \\ [], fun) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, 5000)

    case checkout(pool, timeout: timeout) do
      {:ok, agent_pid} ->
        try do
          result = fun.(agent_pid)
          {:ok, result}
        after
          checkin(pool, agent_pid)
        end

      error ->
        error
    end
  end

  @doc """
  Checks out an agent from the pool.

  ## Options

  - `:timeout` - Maximum time to wait in ms (default: 5000)
  - `:block` - Whether to block if no agents available (default: true)

  ## Examples

      {:ok, agent_pid} = AgentPool.checkout(pool)
      result = AgentProcess.run(agent_pid, input)
      AgentPool.checkin(pool, agent_pid)

      # Non-blocking checkout
      case AgentPool.checkout(pool, block: false) do
        {:ok, agent_pid} -> # use agent
        {:error, :no_agents} -> # pool empty
      end
  """
  @spec checkout(GenServer.server(), keyword()) :: {:ok, pid()} | {:error, term()}
  def checkout(pool, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    block = Keyword.get(opts, :block, true)

    GenServer.call(pool, {:checkout, block}, timeout)
  end

  @doc """
  Returns an agent to the pool.

  ## Examples

      {:ok, agent_pid} = AgentPool.checkout(pool)
      # ... use agent ...
      :ok = AgentPool.checkin(pool, agent_pid)
  """
  @spec checkin(GenServer.server(), pid()) :: :ok
  def checkin(pool, agent_pid) do
    GenServer.cast(pool, {:checkin, agent_pid})
  end

  @doc """
  Returns pool statistics.

  ## Examples

      stats = AgentPool.stats(pool)
      #=> %{
        size: 10,
        available: 7,
        in_use: 3,
        overflow: 0,
        max_overflow: 5,
        waiting: 2
      }
  """
  @spec stats(GenServer.server()) :: pool_stat()
  def stats(pool) do
    GenServer.call(pool, :stats)
  end

  @doc """
  Stops the agent pool gracefully.

  Terminates all agent processes and shuts down the pool.

  ## Examples

      :ok = AgentPool.stop(pool)
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(pool) do
    GenServer.stop(pool, :normal)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    agent_config = Keyword.fetch!(opts, :agent_config)
    size = Keyword.get(opts, :size, 10)
    max_overflow = Keyword.get(opts, :max_overflow, 5)
    strategy = Keyword.get(opts, :strategy, :lifo)

    # Start supervisor for agents
    {:ok, supervisor} = AgentSupervisor.start_link()

    # Initialize state
    state = %State{
      supervisor: supervisor,
      agent_config: agent_config,
      size: size,
      max_overflow: max_overflow,
      strategy: strategy
    }

    # Start initial pool of agents
    state = start_agents(state, size)

    {:ok, state}
  end

  @impl true
  def handle_call({:checkout, block}, from, state) do
    case do_checkout(state) do
      {:ok, agent_pid, new_state} ->
        # Monitor the checking out process
        ref = Process.monitor(agent_pid)
        new_state = put_in(new_state.monitors[ref], agent_pid)

        {:reply, {:ok, agent_pid}, new_state}

      {:error, :no_agents} when block ->
        # Add to waiting queue
        new_state = %{state | waiting: :queue.in(from, state.waiting)}
        {:noreply, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      size: state.size,
      available: length(state.available),
      in_use: MapSet.size(state.in_use),
      overflow: state.overflow_count,
      max_overflow: state.max_overflow,
      waiting: :queue.len(state.waiting)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:checkin, agent_pid}, state) do
    # Check if agent is still alive
    if Process.alive?(agent_pid) do
      new_state = do_checkin(agent_pid, state)
      {:noreply, new_state}
    else
      # Agent died, remove from in_use and potentially create new one
      new_state = handle_agent_death(agent_pid, state)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Agent process died
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {agent_pid, monitors} ->
        new_state = %{state | monitors: monitors}
        new_state = handle_agent_death(agent_pid, new_state)
        {:noreply, new_state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Terminate all agents
    AgentSupervisor.terminate_all(state.supervisor)
    :ok
  end

  # Private Functions

  defp start_agents(state, count) do
    pids =
      1..count
      |> Enum.map(fn _ ->
        start_agent(state)
      end)
      |> Enum.filter(&(&1 != nil))

    %{state | available: pids}
  end

  defp start_agent(state) do
    agent = BaseAgent.init(state.agent_config)

    case AgentSupervisor.start_agent(state.supervisor, agent: agent) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        Logger.error("Failed to start agent in pool: #{inspect(reason)}")
        nil
    end
  end

  defp do_checkout(%State{available: []} = state) do
    # No available agents, check if we can create overflow
    if state.overflow_count < state.max_overflow do
      case start_agent(state) do
        nil ->
          {:error, :failed_to_start_agent}

        agent_pid ->
          new_state = %{
            state
            | in_use: MapSet.put(state.in_use, agent_pid),
              overflow_count: state.overflow_count + 1
          }

          {:ok, agent_pid, new_state}
      end
    else
      {:error, :no_agents}
    end
  end

  defp do_checkout(%State{available: available, strategy: strategy} = state) do
    {agent_pid, remaining} =
      case strategy do
        :lifo -> {List.last(available), Enum.drop(available, -1)}
        :fifo -> {List.first(available), Enum.drop(available, 1)}
      end

    new_state = %{
      state
      | available: remaining,
        in_use: MapSet.put(state.in_use, agent_pid)
    }

    {:ok, agent_pid, new_state}
  end

  defp do_checkin(agent_pid, state) do
    # Remove from in_use
    new_state = %{state | in_use: MapSet.delete(state.in_use, agent_pid)}

    # Check if this is an overflow agent
    is_overflow = length(new_state.available) >= state.size

    cond do
      # There are waiting checkouts
      not :queue.is_empty(new_state.waiting) ->
        {{:value, from}, new_waiting} = :queue.out(new_state.waiting)
        GenServer.reply(from, {:ok, agent_pid})

        %{new_state | waiting: new_waiting, in_use: MapSet.put(new_state.in_use, agent_pid)}

      # Return to pool if not overflow
      not is_overflow ->
        %{new_state | available: [agent_pid | new_state.available]}

      # Overflow agent, terminate it
      true ->
        _ = AgentSupervisor.terminate_agent(state.supervisor, agent_pid)
        %{new_state | overflow_count: max(0, new_state.overflow_count - 1)}
    end
  end

  defp handle_agent_death(agent_pid, state) do
    # Remove from in_use and available
    state = %{
      state
      | in_use: MapSet.delete(state.in_use, agent_pid),
        available: List.delete(state.available, agent_pid)
    }

    # Check if we need to start a replacement
    total_agents = length(state.available) + MapSet.size(state.in_use)

    if total_agents < state.size do
      # Start replacement agent
      case start_agent(state) do
        nil ->
          Logger.warning("Failed to start replacement agent")
          state

        new_pid ->
          # Check if there are waiting checkouts
          if not :queue.is_empty(state.waiting) do
            {{:value, from}, new_waiting} = :queue.out(state.waiting)
            GenServer.reply(from, {:ok, new_pid})

            %{state | waiting: new_waiting, in_use: MapSet.put(state.in_use, new_pid)}
          else
            %{state | available: [new_pid | state.available]}
          end
      end
    else
      # It was an overflow agent
      %{state | overflow_count: max(0, state.overflow_count - 1)}
    end
  end
end
