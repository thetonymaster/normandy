defmodule Normandy.Coordination.Reactive do
  @moduledoc """
  Reactive patterns for event-driven multi-agent coordination.

  Provides high-level patterns for concurrent agent execution with different
  completion strategies: race (first to finish), all (wait for all), and
  some (wait for N successes).

  These combinators emit no `[:normandy, :workflow, :run]` span of their own (a
  current limitation): they are the building blocks `Normandy.DSL.Workflow` uses
  inside its span. Each agent run they start still nests under the caller's span.

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

  ## Telemetry

  `race/3` and `some/3` kill the agents still running once they have their
  answer, and `all/3` kills an agent that runs past `:timeout`. A killed
  agent's `[:normandy, :agent, :run]` span never closes on its own, so these
  functions emit a synthetic `[:normandy, :agent, :run, :exception]` with
  `reason: :killed` for each agent struct they kill before its run returns
  (not for one killed in `on_complete`), possibly without a matching `:start`; the
  `llm_call`/`tool` spans open inside it stay open.
  Agent processes (pids) are not killed, only the task waiting on them, so
  their runs end normally. See `Normandy.Telemetry.KilledRun`.
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Coordination.Reactive
  alias Normandy.Telemetry.KilledRun
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.TurnError

  @type agent_or_pid :: struct() | pid()
  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Races multiple agents and returns the first successful result.

  Starts all agents concurrently and returns as soon as any agent succeeds.
  The agents still running are then killed (see "Telemetry" in the moduledoc).

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
    parent_otel_ctx = OtelCtx.capture()
    started_at = System.monotonic_time()
    run_marks = KilledRun.new_run_marks(length(agents))

    tasks =
      agents
      |> Enum.with_index()
      |> Enum.map(fn {agent, idx} ->
        task =
          Task.async(fn ->
            OtelCtx.restore(parent_otel_ctx)
            agent_id = "agent_#{idx}"
            result = execute_agent(agent, input)
            :ok = KilledRun.mark_run_done(run_marks, idx)

            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            if on_complete, do: on_complete.(agent_id, result)

            send(parent, {ref, agent_id, result})
            result
          end)

        {task, agent, idx}
      end)

    # Wait for first success or all failures
    result = await_first_success(ref, length(agents), timeout)

    # Cleanup: shutdown remaining tasks
    shutdown_tasks(tasks, run_marks, started_at, parent_otel_ctx)

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

  - `{:ok, %{agent_id => result}}` - Map of all results. An agent that runs
    past `:timeout` (the limit applies to each agent) is stopped and appears
    as `{:error, {:exit, :timeout}}`; one whose task exits otherwise, as
    `{:error, {:exit, reason}}`
  - `{:error, reason}` - If fail_fast is true and an agent fails
  - `{:error, {:exit, reason}}` - If fail_fast is true and an agent exits or
    times out
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
      |> Enum.map(fn {agent, idx} -> {agent, "agent_#{idx}", idx} end)

    # Execute with Task.async_stream
    parent_otel_ctx = OtelCtx.capture()
    run_marks = KilledRun.new_run_marks(length(agent_specs))

    results =
      Task.async_stream(
        agent_specs,
        fn {agent, agent_id, idx} ->
          OtelCtx.restore(parent_otel_ctx)
          result = execute_agent(agent, input)
          :ok = KilledRun.mark_run_done(run_marks, idx)
          if on_complete, do: on_complete.(agent_id, result)
          {agent_id, result}
        end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Stream.map(&report_kill(&1, run_marks, timeout, parent_otel_ctx))
      |> Enum.reduce_while({:ok, %{}}, fn
        {:ok, {agent_id, result}}, {:ok, acc} ->
          # Check if we should fail fast
          case {fail_fast, result} do
            {true, {:error, reason}} ->
              {:halt, {:error, reason}}

            _ ->
              {:cont, {:ok, Map.put(acc, agent_id, result)}}
          end

        {:exit, {agent_id, reason}}, {:ok, acc} ->
          if fail_fast do
            {:halt, {:error, {:exit, reason}}}
          else
            {:cont, {:ok, Map.put(acc, agent_id, {:error, {:exit, reason}})}}
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
      parent_otel_ctx = OtelCtx.capture()
      started_at = System.monotonic_time()
      run_marks = KilledRun.new_run_marks(length(agents))

      tasks =
        agents
        |> Enum.with_index()
        |> Enum.map(fn {agent, idx} ->
          task =
            Task.async(fn ->
              OtelCtx.restore(parent_otel_ctx)
              agent_id = "agent_#{idx}"
              result = execute_agent(agent, input)
              :ok = KilledRun.mark_run_done(run_marks, idx)

              # credo:disable-for-next-line Credo.Check.Refactor.Nesting
              if on_complete, do: on_complete.(agent_id, result)

              send(parent, {ref, agent_id, result})
              result
            end)

          {task, agent, idx}
        end)

      # Wait for N successes
      result = await_n_successes(ref, count, length(agents), timeout)

      # Cleanup
      shutdown_tasks(tasks, run_marks, started_at, parent_otel_ctx)

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
      result = Reactive.execute_agent(unquote(agent), unquote(input))

      case result do
        unquote(clauses)
      end
    end
  end

  # Private Functions

  # Kills the tasks still running. A task killed before its run returned left
  # its agent's run span open: report it.
  defp shutdown_tasks(tasks, run_marks, started_at, otel_ctx) do
    Enum.each(tasks, fn {task, agent, idx} ->
      killed? = Task.shutdown(task, :brutal_kill) == nil

      if killed? and not KilledRun.run_done?(run_marks, idx) do
        KilledRun.emit(agent, System.monotonic_time() - started_at, otel_ctx)
      end
    end)
  end

  # A task killed past the timeout before its run returned left its agent's run
  # span open: report it. Reduces the input zip_input_on_exit added to the
  # agent id.
  defp report_kill({:exit, {{agent, agent_id, idx}, reason}}, run_marks, timeout, otel_ctx) do
    if reason == :timeout and not KilledRun.run_done?(run_marks, idx),
      do: KilledRun.emit_timeout(agent, timeout, otel_ctx)

    {:exit, {agent_id, reason}}
  end

  defp report_kill(result, _run_marks, _timeout, _otel_ctx), do: result

  @doc false
  def execute_agent(agent, input) when is_pid(agent) do
    # Agent process
    AgentProcess.run(agent, input)
  end

  def execute_agent(agent, input) do
    # Agent struct
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, _updated_agent, response} -> {:ok, response}
      {:error, exception} -> {:error, exception}
    end
  rescue
    e -> TurnError.log_raised("Reactive agent", e, __STACKTRACE__)
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
