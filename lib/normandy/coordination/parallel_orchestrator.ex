defmodule Normandy.Coordination.ParallelOrchestrator do
  @moduledoc """
  Orchestrates parallel execution of multiple agents.

  The Parallel Orchestrator runs multiple agents concurrently, each working
  on the same or different inputs. Results are collected and can be
  aggregated using a custom function.

  ## Example

      # Define agents
      agents = [
        %{id: "researcher_1", agent: research_agent_1, input: query1},
        %{id: "researcher_2", agent: research_agent_2, input: query2},
        %{id: "researcher_3", agent: research_agent_3, input: query3}
      ]

      # Execute in parallel
      {:ok, results} = ParallelOrchestrator.execute(
        agents,
        max_concurrency: 3,
        aggregate: &combine_research_results/1
      )

  ## Telemetry

  An agent that runs past `:timeout` is killed mid-run, so its
  `[:normandy, :agent, :run]` span never closes on its own. `execute/2` and
  `execute_stream/2` emit a synthetic `[:normandy, :agent, :run, :exception]`
  with `reason: :killed` for it (`execute_stream/2` when the timed-out element
  is consumed), possibly without a matching `:start`; the `llm_call`/`tool`
  spans open inside it stay open. See `Normandy.Telemetry.KilledRun`.
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.SharedContext
  alias Normandy.Telemetry.KilledRun
  alias Normandy.Telemetry.OtelCtx

  @type agent_spec :: %{
          required(:id) => String.t(),
          required(:agent) => struct(),
          required(:input) => term(),
          optional(:transform) => (term() -> term())
        }

  @type execution_result :: %{
          success: boolean(),
          results: %{String.t() => term()},
          errors: %{String.t() => term()},
          context: SharedContext.t(),
          aggregated: term() | nil
        }

  @doc """
  Executes agents in parallel.

  Can be called in two ways:
  1. With agent_specs and options: `execute(agent_specs, opts)`
  2. With agents list and input: `execute(agents, input)` - returns
     `{:ok, [{:ok, result} | {:error, reason}]}`, one entry per agent in order

  ## Options

  - `:shared_context` - SharedContext to use (default: new context)
  - `:max_concurrency` - Maximum concurrent agents (default: 10)
  - `:timeout` - Timeout per agent in ms (default: 300_000). An agent that runs
    past it is stopped and reported in `errors` as `{:exit, :timeout}`.
    An agent that raises is reported as `{:exception, e, stacktrace}`, and
    one that exits as `{:exit, reason}`; neither stops the others or the caller.
  - `:aggregate` - Function to aggregate results: `([{id, result}] -> term())`
  - `:on_agent_complete` - Callback: `(agent_id, result -> any)`
  - `:ordered` - Return results in spec order (default: false)

  ## Example

      {:ok, result} = ParallelOrchestrator.execute(
        agents,
        max_concurrency: 5,
        aggregate: fn results ->
          Enum.map(results, fn {_id, r} -> r end)
          |> Enum.join("\\n")
        end
      )
  """
  @spec execute([agent_spec()] | [struct()], keyword() | map()) ::
          {:ok, execution_result()} | {:ok, list()}
  def execute(agents, input_or_opts \\ [])

  # Simple API: execute(agents, input) -> {:ok, [results]}
  def execute(agents, input)
      when is_list(agents) and (is_map(input) or is_binary(input)) do
    # Ensure input is not a struct (use plain maps only for simple API)
    cond do
      is_binary(input) ->
        execute_simple_api(agents, input)

      is_map(input) and not is_map_key(input, :__struct__) ->
        execute_simple_api(agents, input)

      true ->
        # If opts is a keyword list (which is a list), use advanced API
        execute_with_specs(agents, [])
    end
  end

  # Advanced API: execute(agent_specs, opts) -> {:ok, execution_result}
  def execute(agent_specs, opts) when is_list(agent_specs) and is_list(opts) do
    execute_with_specs(agent_specs, opts)
  end

  defp execute_simple_api(agents, input) do
    # Generate agent specs with unique IDs
    agent_specs =
      agents
      |> Enum.with_index()
      |> Enum.map(fn {agent, idx} ->
        %{
          id: "agent_#{idx}",
          agent: agent,
          input: input
        }
      end)

    {:ok, %{results: results, errors: errors}} = execute_with_specs(agent_specs, [])

    # One entry per agent, in agent order, so a failure keeps its place.
    {:ok,
     Enum.map(agent_specs, fn %{id: id} ->
       case Map.fetch(results, id) do
         {:ok, result} -> {:ok, result}
         :error -> {:error, Map.fetch!(errors, id)}
       end
     end)}
  end

  defp execute_with_specs(agent_specs, opts) when is_list(agent_specs) do
    context = Keyword.get(opts, :shared_context, SharedContext.new())
    max_concurrency = Keyword.get(opts, :max_concurrency, 10)
    timeout = Keyword.get(opts, :timeout, 300_000)
    aggregate_fn = Keyword.get(opts, :aggregate)
    on_complete = Keyword.get(opts, :on_agent_complete)
    ordered = Keyword.get(opts, :ordered, false)

    # Execute agents in parallel using Task.async_stream
    parent_otel_ctx = OtelCtx.capture()

    results =
      Task.async_stream(
        agent_specs,
        fn spec ->
          OtelCtx.restore(parent_otel_ctx)
          {Map.fetch!(spec, :id), run_spec(spec, on_complete)}
        end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        # A slow agent fails on its own instead of exiting the caller.
        on_timeout: :kill_task,
        zip_input_on_exit: true,
        ordered: ordered
      )
      |> Enum.to_list()

    Enum.each(results, &report_kill(&1, timeout, parent_otel_ctx))

    # Separate successes and errors
    {successes, errors} =
      Enum.reduce(results, {%{}, %{}}, fn
        {:ok, {agent_id, {:ok, result}}}, {succ, err} ->
          {Map.put(succ, agent_id, result), err}

        {:ok, {agent_id, {:error, reason}}}, {succ, err} ->
          {succ, Map.put(err, agent_id, reason)}

        {:exit, {%{id: agent_id}, reason}}, {succ, err} ->
          {succ, Map.put(err, agent_id, {:exit, reason})}
      end)

    # Aggregate results if function provided
    aggregated =
      if aggregate_fn && map_size(successes) > 0 do
        aggregate_fn.(Map.to_list(successes))
      else
        nil
      end

    # Store results in context
    updated_context =
      Enum.reduce(successes, context, fn {agent_id, result}, ctx ->
        SharedContext.put(ctx, {"results", agent_id}, result)
      end)

    {:ok,
     %{
       success: map_size(errors) == 0,
       results: successes,
       errors: errors,
       context: updated_context,
       aggregated: aggregated
     }}
  end

  @doc """
  Executes agents with the same input in parallel.

  All agents receive the same input and work on it concurrently.

  ## Example

      # Multiple agents analyze the same data
      {:ok, results} = ParallelOrchestrator.execute_same_input(
        agents,
        input_data,
        max_concurrency: 5
      )
  """
  @spec execute_same_input([%{id: String.t(), agent: struct()}], term(), keyword()) ::
          {:ok, execution_result()}
  def execute_same_input(agents, input, opts \\ []) do
    # Convert to full agent specs with same input
    agent_specs =
      Enum.map(agents, fn agent_info ->
        %{
          id: Map.fetch!(agent_info, :id),
          agent: Map.fetch!(agent_info, :agent),
          input: input,
          transform: Map.get(agent_info, :transform)
        }
      end)

    execute(agent_specs, opts)
  end

  @doc """
  Executes agents and collects results as they complete.

  Returns a stream of results as agents finish. Each element is one of:

  - `{:ok, {:ok, {agent_id, result}}}` - the agent finished
  - `{:ok, {:error, {agent_id, reason}}}` - the agent raised or exited (see `execute/2`)
  - `{:exit, {agent_id, :timeout}}` - the agent ran past `:timeout` and was stopped

  ## Example

      stream = ParallelOrchestrator.execute_stream(agents, timeout: 60_000)

      stream
      |> Stream.each(fn
        {:ok, {:ok, {agent_id, result}}} -> IO.puts("Agent \#{agent_id}: \#{inspect(result)}")
        {:ok, {:error, {agent_id, reason}}} -> IO.puts("Agent \#{agent_id} failed: \#{inspect(reason)}")
        {:exit, {agent_id, :timeout}} -> IO.puts("Agent \#{agent_id} timed out")
      end)
      |> Stream.run()
  """
  @spec execute_stream([agent_spec()], keyword()) :: Enumerable.t()
  def execute_stream(agent_specs, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 10)
    timeout = Keyword.get(opts, :timeout, 300_000)

    parent_otel_ctx = OtelCtx.capture()

    Task.async_stream(
      agent_specs,
      fn spec ->
        OtelCtx.restore(parent_otel_ctx)
        agent_id = Map.fetch!(spec, :id)

        case run_spec(spec, nil) do
          {:ok, transformed} -> {:ok, {agent_id, transformed}}
          {:error, reason} -> {:error, {agent_id, reason}}
        end
      end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      # A slow agent fails on its own instead of exiting the caller.
      on_timeout: :kill_task,
      zip_input_on_exit: true,
      ordered: false
    )
    |> Stream.map(fn
      {:exit, {%{id: agent_id}, reason}} = exit ->
        :ok = report_kill(exit, timeout, parent_otel_ctx)
        {:exit, {agent_id, reason}}

      other ->
        other
    end)
  end

  # Private functions

  # An agent past the timeout was killed mid-run, so its run span never closed.
  defp report_kill({:exit, {%{agent: agent}, :timeout}}, timeout, otel_ctx),
    do: KilledRun.emit_timeout(agent, timeout, otel_ctx)

  defp report_kill(_result, _timeout, _otel_ctx), do: :ok

  defp execute_agent(agent, input) do
    # Convert input to agent input format if needed
    agent_input = prepare_input(input)

    # Run agent
    {_updated_agent, response} = BaseAgent.run(agent, agent_input)

    # Extract result from response
    result = extract_result(response)

    {:ok, result}
  rescue
    e ->
      {:error, {:exception, e, __STACKTRACE__}}
  catch
    # An exit (a timed-out GenServer.call, say) would otherwise end the task and,
    # through its link, the caller.
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  # Runs one spec's agent, then its :transform and the :on_agent_complete callback.
  # The callbacks run in the agent's task, so they are guarded: a crash would take
  # the caller down through the task's link.
  defp run_spec(spec, on_complete) do
    with {:ok, result} <- execute_agent(Map.fetch!(spec, :agent), Map.fetch!(spec, :input)) do
      guarded(fn -> run_callbacks(spec, result, on_complete) end)
    end
  end

  defp run_callbacks(spec, result, on_complete) do
    transformed = (Map.get(spec, :transform) || (& &1)).(result)
    if on_complete, do: on_complete.(Map.fetch!(spec, :id), transformed)
    transformed
  end

  # A crash in a spec's callbacks is that agent's error, in execute_agent/2's shapes.
  defp guarded(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, {:exception, e, __STACKTRACE__}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp prepare_input(input) when is_map(input) do
    # Check if it's a struct
    if is_map_key(input, :__struct__) do
      # It's a struct, return as-is
      input
    else
      # Plain map - try to extract chat_message if present
      Map.get(input, :chat_message) || Map.get(input, "chat_message") || input
    end
  end

  defp prepare_input(input) when is_binary(input) do
    %{chat_message: input}
  end

  defp prepare_input(input), do: input

  defp extract_result(response) when is_map(response) do
    # Return the full response map - don't extract just chat_message
    response
  end
end
