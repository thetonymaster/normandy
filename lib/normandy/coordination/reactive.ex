defmodule Normandy.Coordination.Reactive do
  @moduledoc """
  Reactive patterns for event-driven multi-agent coordination.

  Provides high-level patterns for concurrent agent execution with different
  completion strategies: race (first to finish), all (wait for all), and
  some (wait for N successes).

  ## Examples

      # Race: Return first successful result
      {:ok, result} = Reactive.race([agent1, agent2, agent3], input, timeout: 5000)

      # All: Wait for all agents to complete
      {:ok, results} = Reactive.all([agent1, agent2, agent3], input, timeout: 10000)

      # Some: Wait for N successful results
      {:ok, results} = Reactive.some([agent1, agent2, agent3], input, count: 2)

      # With agent processes
      {:ok, result} = Reactive.race([pid1, pid2], input)

  ## Use Cases

  - **Race**: Get fastest response for latency-sensitive operations
  - **All**: Ensemble methods, need all perspectives
  - **Some**: Quorum-based decisions, need majority agreement
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.AgentProcess

  @type agent_or_pid :: struct() | pid()
  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Races multiple agents and returns the first successful result.

  Starts all agents concurrently and returns as soon as any agent succeeds.
  Other agents continue running in the background but their results are ignored.

  ## Options

  - `:timeout` - Maximum time to wait in ms (default: 60_000)
  - `:on_complete` - Callback `fn agent_id, result -> any end`

  ## Examples

      # With agent structs
      {:ok, fastest_result} = Reactive.race(
        [research_agent, search_agent, cached_agent],
        query,
        timeout: 5000
      )

      # With agent processes
      {:ok, result} = Reactive.race([pid1, pid2, pid3], input)

      # With callback
      Reactive.race(agents, input,
        on_complete: fn agent_id, result ->
          Logger.info("Agent \#{agent_id} completed: \#{inspect(result)}")
        end
      )

  ## Returns

  - `{:ok, result}` - First successful result
  - `{:error, :all_failed}` - All agents failed
  - `{:error, :timeout}` - Timeout reached before any success
  """
  @spec race([agent_or_pid()], term(), keyword()) :: result()
  def race(agents, input, opts \\ []) when is_list(agents) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    on_complete = Keyword.get(opts, :on_complete)

    # Create parent task that manages agent tasks
    parent = self()
    ref = make_ref()

    # Start all agent tasks
    tasks =
      agents
      |> Enum.with_index()
      |> Enum.map(fn {agent, idx} ->
        Task.async(fn ->
          agent_id = "agent_#{idx}"
          result = execute_agent(agent, input)

          if on_complete, do: on_complete.(agent_id, result)

          send(parent, {ref, agent_id, result})
          result
        end)
      end)

    # Wait for first success or all failures
    result = await_first_success(ref, length(agents), timeout)

    # Cleanup: shutdown remaining tasks
    Enum.each(tasks, fn task -> Task.shutdown(task, :brutal_kill) end)

    result
  end

  @doc """
  Waits for all agents to complete and returns all results.

  Executes all agents concurrently and waits for all to finish, collecting
  both successes and failures.

  ## Options

  - `:timeout` - Maximum time to wait in ms (default: 60_000)
  - `:max_concurrency` - Maximum concurrent agents (default: length of agents)
  - `:on_complete` - Callback `fn agent_id, result -> any end`
  - `:fail_fast` - Stop on first failure (default: false)

  ## Examples

      # Get all results
      {:ok, results} = Reactive.all([agent1, agent2, agent3], input)
      #=> {:ok, %{
             "agent_0" => {:ok, result1},
             "agent_1" => {:ok, result2},
             "agent_2" => {:error, reason}
           }}

      # With concurrency limit
      {:ok, results} = Reactive.all(many_agents, input, max_concurrency: 5)

      # Fail fast on first error
      {:error, reason} = Reactive.all(agents, input, fail_fast: true)

  ## Returns

  - `{:ok, %{agent_id => result}}` - Map of all results
  - `{:error, reason}` - If fail_fast is true and an agent fails
  - `{:error, :timeout}` - If timeout is reached
  """
  @spec all([agent_or_pid()], term(), keyword()) :: {:ok, %{String.t() => result()}} | result()
  def all(agents, input, opts \\ []) when is_list(agents) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    max_concurrency = Keyword.get(opts, :max_concurrency, length(agents))
    on_complete = Keyword.get(opts, :on_complete)
    fail_fast = Keyword.get(opts, :fail_fast, false)

    agent_specs =
      agents
      |> Enum.with_index()
      |> Enum.map(fn {agent, idx} -> {agent, "agent_#{idx}"} end)

    # Execute with Task.async_stream
    results =
      Task.async_stream(
        agent_specs,
        fn {agent, agent_id} ->
          result = execute_agent(agent, input)
          if on_complete, do: on_complete.(agent_id, result)
          {agent_id, result}
        end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while({:ok, %{}}, fn
        {:ok, {agent_id, result}}, {:ok, acc} ->
          # Check if we should fail fast
          case {fail_fast, result} do
            {true, {:error, reason}} ->
              {:halt, {:error, reason}}

            _ ->
              {:cont, {:ok, Map.put(acc, agent_id, result)}}
          end

        {:exit, reason}, _acc ->
          if fail_fast do
            {:halt, {:error, {:exit, reason}}}
          else
            {:cont, {:ok, %{}}}
          end
      end)

    results
  end

  @doc """
  Waits for N successful results from agents.

  Executes agents concurrently until the specified number of successful
  results is reached. Useful for quorum-based decisions.

  ## Options

  - `:count` - Number of successful results needed (required)
  - `:timeout` - Maximum time to wait in ms (default: 60_000)
  - `:on_complete` - Callback `fn agent_id, result -> any end`

  ## Examples

      # Wait for 2 out of 3 agents to succeed (quorum)
      {:ok, results} = Reactive.some(
        [agent1, agent2, agent3],
        input,
        count: 2,
        timeout: 10000
      )
      #=> {:ok, %{"agent_0" => result1, "agent_2" => result3}}

      # Majority vote
      agents = [voter1, voter2, voter3, voter4, voter5]
      {:ok, votes} = Reactive.some(agents, question, count: 3)

  ## Returns

  - `{:ok, %{agent_id => result}}` - Map of N successful results
  - `{:error, :insufficient_successes}` - Not enough agents succeeded
  - `{:error, :timeout}` - Timeout reached before N successes
  """
  @spec some([agent_or_pid()], term(), keyword()) :: {:ok, %{String.t() => term()}} | result()
  def some(agents, input, opts) when is_list(agents) do
    count = Keyword.fetch!(opts, :count)
    timeout = Keyword.get(opts, :timeout, 60_000)
    on_complete = Keyword.get(opts, :on_complete)

    if count > length(agents) do
      {:error, :count_exceeds_agent_count}
    else
      parent = self()
      ref = make_ref()

      # Start all agent tasks
      tasks =
        agents
        |> Enum.with_index()
        |> Enum.map(fn {agent, idx} ->
          Task.async(fn ->
            agent_id = "agent_#{idx}"
            result = execute_agent(agent, input)

            if on_complete, do: on_complete.(agent_id, result)

            send(parent, {ref, agent_id, result})
            result
          end)
        end)

      # Wait for N successes
      result = await_n_successes(ref, count, length(agents), timeout)

      # Cleanup
      Enum.each(tasks, fn task -> Task.shutdown(task, :brutal_kill) end)

      result
    end
  end

  @doc """
  Executes an agent and applies a transformation if successful.

  Useful for chaining operations based on agent responses.

  ## Examples

      result = Reactive.map(agent, input, fn
        {:ok, %{confidence: c}} when c > 0.8 ->
          {:ok, :high_confidence}

        {:ok, %{confidence: c}} when c < 0.5 ->
          {:ok, :low_confidence}

        {:ok, _} ->
          {:ok, :medium_confidence}

        error ->
          error
      end)
  """
  @spec map(agent_or_pid(), term(), (result() -> result())) :: result()
  def map(agent, input, transform_fn) do
    result = execute_agent(agent, input)
    transform_fn.(result)
  end

  @doc """
  Executes an agent and conditionally executes another based on the result.

  ## Examples

      Reactive.when_result(agent1, input) do
        {:ok, %{needs_review: true}} ->
          AgentProcess.run(review_agent, "Please review")

        {:ok, %{confidence: c}} when c < 0.5 ->
          AgentProcess.run(fallback_agent, "Use fallback")

        {:ok, result} ->
          {:ok, result}

        error ->
          error
      end
  """
  defmacro when_result(agent, input, do: clauses) do
    quote do
      result = Normandy.Coordination.Reactive.execute_agent(unquote(agent), unquote(input))

      case result do
        unquote(clauses)
      end
    end
  end

  # Private Functions

  @doc false
  def execute_agent(agent, input) when is_pid(agent) do
    # Agent process
    AgentProcess.run(agent, input)
  end

  def execute_agent(agent, input) do
    # Agent struct
    try do
      agent_input = prepare_input(input)
      {_updated_agent, response} = BaseAgent.run(agent, agent_input)
      {:ok, response}
    rescue
      e ->
        {:error, {:exception, e, __STACKTRACE__}}
    end
  end

  defp prepare_input(input) when is_map(input) and not is_struct(input) do
    Map.get(input, :chat_message) || Map.get(input, "chat_message") || input
  end

  defp prepare_input(input) when is_binary(input), do: %{chat_message: input}
  defp prepare_input(input), do: input

  defp await_first_success(ref, total_agents, timeout) do
    start_time = System.monotonic_time(:millisecond)

    await_first_success_loop(ref, total_agents, 0, start_time, timeout)
  end

  defp await_first_success_loop(_ref, total_agents, failures, _start_time, _timeout)
       when failures >= total_agents do
    {:error, :all_failed}
  end

  defp await_first_success_loop(ref, total_agents, failures, start_time, timeout) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    remaining_timeout = timeout - elapsed

    if remaining_timeout <= 0 do
      {:error, :timeout}
    else
      receive do
        {^ref, _agent_id, {:ok, result}} ->
          {:ok, result}

        {^ref, _agent_id, {:error, _reason}} ->
          await_first_success_loop(ref, total_agents, failures + 1, start_time, timeout)
      after
        remaining_timeout ->
          {:error, :timeout}
      end
    end
  end

  defp await_n_successes(ref, count, total_agents, timeout) do
    start_time = System.monotonic_time(:millisecond)
    await_n_successes_loop(ref, count, total_agents, %{}, 0, start_time, timeout)
  end

  defp await_n_successes_loop(_ref, count, _total, successes, _failures, _start, _timeout)
       when map_size(successes) >= count do
    {:ok, successes}
  end

  defp await_n_successes_loop(_ref, count, total, successes, failures, _start, _timeout)
       when map_size(successes) + (total - map_size(successes) - failures) < count do
    # Not enough agents left to reach count
    {:error, :insufficient_successes}
  end

  defp await_n_successes_loop(ref, count, total, successes, failures, start_time, timeout) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    remaining_timeout = timeout - elapsed

    if remaining_timeout <= 0 do
      {:error, :timeout}
    else
      receive do
        {^ref, agent_id, {:ok, result}} ->
          updated_successes = Map.put(successes, agent_id, result)

          await_n_successes_loop(
            ref,
            count,
            total,
            updated_successes,
            failures,
            start_time,
            timeout
          )

        {^ref, _agent_id, {:error, _reason}} ->
          await_n_successes_loop(
            ref,
            count,
            total,
            successes,
            failures + 1,
            start_time,
            timeout
          )
      after
        remaining_timeout ->
          {:error, :timeout}
      end
    end
  end
end
