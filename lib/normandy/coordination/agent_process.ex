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
  """

  use GenServer
  require Logger

  alias Normandy.Agents.BaseAgent

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
    agent = Keyword.fetch!(opts, :agent)
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

    state = %{
      agent: agent,
      agent_id: agent_id,
      context_pid: context_pid,
      run_count: 0,
      last_run: nil,
      total_runtime_ms: 0,
      created_at: DateTime.utc_now()
    }

    {:ok, state}
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
  def handle_call({:update_agent, update_fn}, _from, state) do
    updated_agent = update_fn.(state.agent)
    {:reply, :ok, %{state | agent: updated_agent}}
  end

  @impl true
  def handle_cast({:run_async, input, reply_to}, state) do
    # Spawn task to run agent without blocking GenServer
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

  defp extract_result(response), do: response

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
end
