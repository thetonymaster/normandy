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
      # agent pid => monitor ref, for every agent the pool started
      agents: %{},
      # client monitor ref => the agent that client holds
      clients: %{}
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
          model: "claude-opus-5-5"
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
  The agent is returned to the pool even when the function raises.

  ## Options

  - `:timeout` - Checkout timeout in ms, or `:infinity` (default: 5000)

  ## Examples

      {:ok, result} = AgentPool.transaction(pool, fn agent_pid ->
        AgentProcess.run(agent_pid, "Analyze this data")
      end)

      # With timeout
      {:ok, result} = AgentPool.transaction(pool, [timeout: 10_000], fn agent_pid ->
        AgentProcess.run(agent_pid, input)
      end)

  ## Returns

  - `{:ok, result}` - the function's return value, whatever it is: a function
    that returns `{:error, reason}` gives `{:ok, {:error, reason}}`
  - `{:error, :timeout}` - no agent became available within `:timeout`
  - `{:error, :failed_to_start_agent}` - the pool tried to start an overflow
    agent and could not

  A function that raises or exits is not caught: the error propagates to the
  caller after the agent is checked back in.
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

  - `:timeout` - Maximum time to wait in ms, or `:infinity` (default: 5000)
  - `:block` - Whether to block if no agents available (default: true)

  ## Returns

  - `{:ok, agent_pid}`
  - `{:error, :timeout}` - blocking, and no agent became available within `:timeout`
  - `{:error, :no_agents}` - non-blocking, and every agent is in use with the
    overflow limit reached
  - `{:error, :failed_to_start_agent}` - the pool could not start an overflow agent

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

    unless timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
      raise ArgumentError,
            "AgentPool.checkout/2: invalid :timeout, expected a non-negative integer " <>
              "or :infinity, got #{inspect(timeout)}"
    end

    # The pool enforces the timeout and always replies, so a caller never exits
    # on a busy pool and an agent is never handed to a caller that gave up.
    GenServer.call(pool, {:checkout, block, timeout}, :infinity)
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
  def handle_call({:checkout, block, timeout}, {client, _tag} = from, state) do
    case do_checkout(state) do
      {:ok, agent_pid, new_state} ->
        {:reply, {:ok, agent_pid}, lend(agent_pid, client, new_state)}

      {:error, :no_agents} when block ->
        # Watch the waiter, so one that dies is dropped instead of being handed an agent.
        mref = Process.monitor(client)
        timer = start_checkout_timer(from, timeout)
        {:noreply, %{state | waiting: :queue.in({from, timer, mref}, state.waiting)}}

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
    case release(agent_pid, state) do
      # Not checked out (a second checkin, or a pid the pool never lent): ignore it.
      :not_lent ->
        {:noreply, state}

      # A dead agent is left in use; its :DOWN removes and replaces it.
      {:ok, state} ->
        {:noreply, if(Process.alive?(agent_pid), do: do_checkin(agent_pid, state), else: state)}
    end
  end

  @impl true
  def handle_info({:checkout_timeout, from}, state) do
    # A waiter served just before its timer fired is no longer in the queue.
    {gone, waiting} =
      split_waiters(state.waiting, fn {waiter, _timer, _mref} -> waiter == from end)

    Enum.each(gone, fn {_from, _timer, mref} ->
      Process.demonitor(mref, [:flush])
      GenServer.reply(from, {:error, :timeout})
    end)

    {:noreply, %{state | waiting: waiting}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      Map.get(state.agents, pid) == ref -> {:noreply, agent_down(pid, state)}
      Map.has_key?(state.clients, ref) -> {:noreply, client_down(ref, state)}
      true -> {:noreply, waiter_down(ref, state)}
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
    Enum.reduce(1..count, state, fn _, state ->
      case start_agent(state) do
        {:ok, pid, state} -> %{state | available: state.available ++ [pid]}
        :error -> state
      end
    end)
  end

  # The pool owns replacement, so agents are :temporary: a supervisor restart
  # would add an agent the pool doesn't know about.
  defp start_agent(state) do
    agent = BaseAgent.init(state.agent_config)

    case AgentSupervisor.start_agent(state.supervisor, agent: agent, restart: :temporary) do
      {:ok, pid} ->
        {:ok, pid, put_in(state.agents[pid], Process.monitor(pid))}

      {:error, reason} ->
        Logger.error("Failed to start agent in pool: #{inspect(reason)}")
        :error
    end
  end

  defp stop_agent(agent_pid, state) do
    {ref, agents} = Map.pop(state.agents, agent_pid)
    if ref, do: Process.demonitor(ref, [:flush])
    _ = AgentSupervisor.terminate_agent(state.supervisor, agent_pid)
    %{state | agents: agents}
  end

  # Record that `client` holds `agent_pid`, so the agent comes back if the client dies.
  defp lend(agent_pid, client, state) do
    put_in(state.clients[Process.monitor(client)], agent_pid)
  end

  defp release(agent_pid, state) do
    case Enum.find(state.clients, fn {_ref, pid} -> pid == agent_pid end) do
      nil ->
        :not_lent

      {ref, _} ->
        Process.demonitor(ref, [:flush])
        {:ok, %{state | clients: Map.delete(state.clients, ref)}}
    end
  end

  defp agent_down(agent_pid, state) do
    state = %{state | agents: Map.delete(state.agents, agent_pid)}

    state =
      case release(agent_pid, state) do
        {:ok, state} -> state
        :not_lent -> state
      end

    handle_agent_death(agent_pid, state)
  end

  defp client_down(ref, state) do
    {agent_pid, clients} = Map.pop(state.clients, ref)
    do_checkin(agent_pid, %{state | clients: clients})
  end

  defp waiter_down(ref, state) do
    {gone, waiting} = split_waiters(state.waiting, fn {_from, _timer, mref} -> mref == ref end)
    Enum.each(gone, fn {_from, timer, _mref} -> cancel_checkout_timer(timer) end)
    %{state | waiting: waiting}
  end

  defp split_waiters(queue, fun) do
    {gone, kept} = Enum.split_with(:queue.to_list(queue), fun)
    {gone, :queue.from_list(kept)}
  end

  defp do_checkout(%State{available: []} = state) do
    # No available agents, check if we can create overflow
    if state.overflow_count < state.max_overflow do
      case start_agent(state) do
        :error ->
          {:error, :failed_to_start_agent}

        {:ok, agent_pid, state} ->
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
        hand_to_waiter(agent_pid, new_state)

      # Return to pool if not overflow
      not is_overflow ->
        %{new_state | available: [agent_pid | new_state.available]}

      # Overflow agent, terminate it
      true ->
        new_state = stop_agent(agent_pid, new_state)
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
        :error ->
          Logger.warning("Failed to start replacement agent")
          state

        {:ok, new_pid, state} ->
          # Check if there are waiting checkouts
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          if :queue.is_empty(state.waiting) do
            %{state | available: [new_pid | state.available]}
          else
            hand_to_waiter(new_pid, state)
          end
      end
    else
      # It was an overflow agent
      %{state | overflow_count: max(0, state.overflow_count - 1)}
    end
  end

  # A waiter with timeout: :infinity has no timer.
  defp start_checkout_timer(_from, :infinity), do: nil

  defp start_checkout_timer(from, timeout),
    do: Process.send_after(self(), {:checkout_timeout, from}, timeout)

  defp cancel_checkout_timer(nil), do: :ok
  defp cancel_checkout_timer(timer), do: _ = Process.cancel_timer(timer)

  defp hand_to_waiter(agent_pid, state) do
    {{:value, {{client, _tag} = from, timer, mref}}, waiting} = :queue.out(state.waiting)
    cancel_checkout_timer(timer)
    Process.demonitor(mref, [:flush])
    GenServer.reply(from, {:ok, agent_pid})

    state = %{state | waiting: waiting, in_use: MapSet.put(state.in_use, agent_pid)}
    lend(agent_pid, client, state)
  end
end
