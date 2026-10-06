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
  alias Normandy.Coordination.Orchestration
  alias Normandy.Coordination.Reactive
  alias Normandy.Telemetry.KilledRun
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.TurnError

  @type agent_or_pid :: struct() | pid()
  @type result ::
          {:ok, term()}
          | {:error, Exception.t() | :all_failed | :timeout | :insufficient_successes}

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

    Orchestration.with_task_supervisor(fn supervisor ->
      started_at = System.monotonic_time()
      parent_otel_ctx = OtelCtx.capture()
      ref = make_ref()

      {tasks, run_marks} = start_tasks(supervisor, agents, input, on_complete, ref)

      # Wait for first success or all failures
      result = await_first_success(ref, monitors(tasks), length(agents), timeout)

      # Cleanup: shutdown remaining tasks
      shutdown_tasks(tasks, run_marks, started_at, parent_otel_ctx)

      result
    end)
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

  - `{:ok, %{agent_id => {:ok, output} | {:error, exception}}}` - every agent's result.
    An agent that runs past `:timeout` (the limit applies to each agent) is stopped and
    appears as `{:error, %Normandy.TurnError{type: :task_down, reason: :timeout}}`; one
    that exits, as that `TurnError` with the exit reason
  - `{:error, exception}` - with `fail_fast: true`, the first failure
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

    # Unlinked tasks: a crash in a process an agent linked to is that agent's exit result.
    Orchestration.with_task_supervisor(fn supervisor ->
      supervisor
      |> Task.Supervisor.async_stream_nolink(
        agent_specs,
        fn {agent, agent_id, idx} ->
          OtelCtx.restore(parent_otel_ctx)
          result = execute_agent(agent, input)
          :ok = KilledRun.mark_run_done(run_marks, idx)
          {agent_id, complete(on_complete, agent_id, result)}
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

        # Killed past :timeout, or the task died.
        {:exit, {agent_id, reason}}, {:ok, acc} ->
          error = TurnError.from_reason({:task_down, reason})

          if fail_fast do
            {:halt, {:error, error}}
          else
            {:cont, {:ok, Map.put(acc, agent_id, {:error, error})}}
          end
      end)
    end)
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
  - Raises `ArgumentError` when `:count` is above the number of agents.
  """
  @spec some([agent_or_pid()], term(), keyword()) :: {:ok, %{String.t() => term()}} | result()
  def some(agents, input, opts) when is_list(agents) do
    count = Keyword.fetch!(opts, :count)
    timeout = Keyword.get(opts, :timeout, 60_000)
    on_complete = Keyword.get(opts, :on_complete)

    if count > length(agents) do
      raise ArgumentError,
            "Normandy.Coordination.Reactive.some/3: :count must be at most the number of " <>
              "agents (#{length(agents)}), got: #{inspect(count)}"
    else
      Orchestration.with_task_supervisor(fn supervisor ->
        started_at = System.monotonic_time()
        parent_otel_ctx = OtelCtx.capture()
        ref = make_ref()

        {tasks, run_marks} = start_tasks(supervisor, agents, input, on_complete, ref)

        # Wait for N successes
        result = await_n_successes(ref, monitors(tasks), count, length(agents), timeout)

        # Cleanup
        shutdown_tasks(tasks, run_marks, started_at, parent_otel_ctx)

        result
      end)
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

  # One unlinked task per agent under `supervisor`. Each reports {ref, agent_id, result}
  # to the caller; a task that dies first is seen through its monitor (see monitors/1).
  defp start_tasks(supervisor, agents, input, on_complete, ref) do
    parent = self()
    parent_otel_ctx = OtelCtx.capture()
    run_marks = KilledRun.new_run_marks(length(agents))

    tasks =
      agents
      |> Enum.with_index()
      |> Enum.map(fn {agent, idx} ->
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            OtelCtx.restore(parent_otel_ctx)
            agent_id = "agent_#{idx}"
            result = execute_agent(agent, input)
            :ok = KilledRun.mark_run_done(run_marks, idx)
            result = complete(on_complete, agent_id, result)

            send(parent, {ref, agent_id, result})
            result
          end)

        {task, agent, idx}
      end)

    {tasks, run_marks}
  end

  # on_complete runs where a crash would lose the agent's result: a raise or a throw in
  # it is that agent's error.
  defp complete(nil, _agent_id, result), do: result

  defp complete(on_complete, agent_id, result) do
    case Orchestration.guard(agent_id, fn -> on_complete.(agent_id, result) end) do
      {:ok, _} -> result
      {:error, exception} -> {:error, exception}
    end
  end

  # monitor ref => agent id, for the tasks started by start_tasks/5.
  defp monitors(tasks),
    do: Map.new(tasks, fn {task, _agent, idx} -> {task.ref, "agent_#{idx}"} end)

  # The next agent outcome, or :timeout. A task that died before reporting (a crash in a
  # process its agent linked to) is that agent's :task_down TurnError.
  defp next_outcome(ref, monitors, remaining) do
    receive do
      {^ref, agent_id, result} ->
        {agent_id, result}

      {:DOWN, mref, :process, _pid, reason}
      when reason != :normal and is_map_key(monitors, mref) ->
        {Map.fetch!(monitors, mref), {:error, TurnError.from_reason({:task_down, reason})}}
    after
      remaining -> :timeout
    end
  end

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
  # One agent's result: {:ok, output} or {:error, exception}. A raise (a bug) is logged
  # and returned; an exit (a timed-out call, a client that exits) is a :task_down
  # TurnError, so it never takes down the task and, through Task.async's link, the caller.
  def execute_agent(agent, input) do
    run_one(agent, input)
  rescue
    e -> TurnError.log_raised("Reactive agent", e, __STACKTRACE__)
  catch
    :exit, reason -> {:error, TurnError.from_reason({:task_down, reason})}
    :throw, value -> {:error, TurnError.from_reason({:task_down, {:nocatch, value}})}
  end

  defp run_one(pid, input) when is_pid(pid), do: AgentProcess.run(pid, input)

  defp run_one(agent, input) do
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, _updated_agent, response} -> {:ok, response}
      {:error, exception} -> {:error, exception}
    end
  end

  defp prepare_input(input) when is_map(input) and not is_struct(input) do
    Map.get(input, :chat_message) || Map.get(input, "chat_message") || input
  end

  defp prepare_input(input) when is_binary(input), do: %{chat_message: input}
  defp prepare_input(input), do: input

  defp remaining(:infinity, _start_time), do: :infinity

  defp remaining(timeout, start_time),
    do: timeout - (System.monotonic_time(:millisecond) - start_time)

  defp await_first_success(ref, monitors, total_agents, timeout) do
    start_time = System.monotonic_time(:millisecond)

    await_first_success_loop(ref, monitors, total_agents, 0, start_time, timeout)
  end

  defp await_first_success_loop(_ref, _monitors, total_agents, failures, _start_time, _timeout)
       when failures >= total_agents do
    {:error, :all_failed}
  end

  defp await_first_success_loop(ref, monitors, total_agents, failures, start_time, timeout) do
    remaining_timeout = remaining(timeout, start_time)

    if remaining_timeout != :infinity and remaining_timeout <= 0 do
      {:error, :timeout}
    else
      case next_outcome(ref, monitors, remaining_timeout) do
        {_agent_id, {:ok, result}} ->
          {:ok, result}

        {_agent_id, {:error, _reason}} ->
          await_first_success_loop(ref, monitors, total_agents, failures + 1, start_time, timeout)

        :timeout ->
          {:error, :timeout}
      end
    end
  end

  defp await_n_successes(ref, monitors, count, total_agents, timeout) do
    start_time = System.monotonic_time(:millisecond)

    await_n_successes_loop(ref, monitors, {count, total_agents}, {%{}, 0}, start_time, timeout)
  end

  defp await_n_successes_loop(_ref, _monitors, {count, _total}, {successes, _failures}, _s, _t)
       when map_size(successes) >= count do
    {:ok, successes}
  end

  defp await_n_successes_loop(_ref, _monitors, {count, total}, {successes, failures}, _s, _t)
       when map_size(successes) + (total - map_size(successes) - failures) < count do
    # Not enough agents left to reach count
    {:error, :insufficient_successes}
  end

  defp await_n_successes_loop(ref, monitors, goal, {successes, failures}, start_time, timeout) do
    remaining_timeout = remaining(timeout, start_time)

    if remaining_timeout != :infinity and remaining_timeout <= 0 do
      {:error, :timeout}
    else
      case next_outcome(ref, monitors, remaining_timeout) do
        {agent_id, {:ok, result}} ->
          tally = {Map.put(successes, agent_id, result), failures}
          await_n_successes_loop(ref, monitors, goal, tally, start_time, timeout)

        {_agent_id, {:error, _reason}} ->
          tally = {successes, failures + 1}
          await_n_successes_loop(ref, monitors, goal, tally, start_time, timeout)

        :timeout ->
          {:error, :timeout}
      end
    end
  end
end
