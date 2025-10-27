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
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{AgentMessage, SharedContext}

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
  2. With agents list and input: `execute(agents, input)` - returns list of results

  ## Options

  - `:shared_context` - SharedContext to use (default: new context)
  - `:max_concurrency` - Maximum concurrent agents (default: 10)
  - `:timeout` - Timeout per agent in ms (default: 300_000)
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
      when is_list(agents) and (is_map(input) or is_binary(input)) and not is_struct(input) do
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

    # Execute with specs
    case execute_with_specs(agent_specs, []) do
      {:ok, %{results: results}} ->
        # Convert map of results to ordered list
        result_list =
          agent_specs
          |> Enum.map(fn %{id: id} -> Map.get(results, id) end)
          |> Enum.filter(&(&1 != nil))

        {:ok, result_list}

      error ->
        error
    end
  end

  # Advanced API: execute(agent_specs, opts) -> {:ok, execution_result}
  def execute(agent_specs, opts) when is_list(agent_specs) and is_list(opts) do
    execute_with_specs(agent_specs, opts)
  end

  defp execute_with_specs(agent_specs, opts) when is_list(agent_specs) do
    context = Keyword.get(opts, :shared_context, SharedContext.new())
    max_concurrency = Keyword.get(opts, :max_concurrency, 10)
    timeout = Keyword.get(opts, :timeout, 300_000)
    aggregate_fn = Keyword.get(opts, :aggregate)
    on_complete = Keyword.get(opts, :on_agent_complete)
    ordered = Keyword.get(opts, :ordered, false)

    # Execute agents in parallel using Task.async_stream
    results =
      Task.async_stream(
        agent_specs,
        fn spec ->
          agent_id = Map.fetch!(spec, :id)
          agent = Map.fetch!(spec, :agent)
          input = Map.fetch!(spec, :input)
          transform_fn = Map.get(spec, :transform, & &1)

          # Execute agent
          result =
            case execute_agent(agent, input) do
              {:ok, agent_result} ->
                transformed = transform_fn.(agent_result)

                # Call completion callback if provided
                if on_complete do
                  on_complete.(agent_id, transformed)
                end

                {:ok, transformed}

              {:error, reason} ->
                {:error, reason}
            end

          {agent_id, result}
        end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        ordered: ordered
      )
      |> Enum.to_list()

    # Separate successes and errors
    {successes, errors} =
      Enum.reduce(results, {%{}, %{}}, fn
        {:ok, {agent_id, {:ok, result}}}, {succ, err} ->
          {Map.put(succ, agent_id, result), err}

        {:ok, {agent_id, {:error, reason}}}, {succ, err} ->
          {succ, Map.put(err, agent_id, reason)}

        {:exit, {agent_id, reason}}, {succ, err} ->
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

  Returns a stream of results as agents finish.

  ## Example

      stream = ParallelOrchestrator.execute_stream(agents)

      stream
      |> Stream.each(fn {:ok, {agent_id, result}} ->
        IO.puts("Agent \#{agent_id}: \#{inspect(result)}")
      end)
      |> Stream.run()
  """
  @spec execute_stream([agent_spec()], keyword()) :: Enumerable.t()
  def execute_stream(agent_specs, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 10)
    timeout = Keyword.get(opts, :timeout, 300_000)

    Task.async_stream(
      agent_specs,
      fn spec ->
        agent_id = Map.fetch!(spec, :id)
        agent = Map.fetch!(spec, :agent)
        input = Map.fetch!(spec, :input)
        transform_fn = Map.get(spec, :transform, & &1)

        case execute_agent(agent, input) do
          {:ok, result} -> {:ok, {agent_id, transform_fn.(result)}}
          {:error, reason} -> {:error, {agent_id, reason}}
        end
      end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      ordered: false
    )
  end

  # Private functions

  defp execute_agent(agent, input) do
    try do
      # Convert input to agent input format if needed
      agent_input = prepare_input(input)

      # Run agent
      {updated_agent, response} = BaseAgent.run(agent, agent_input)

      # Extract result from response
      result = extract_result(response)

      {:ok, result}
    rescue
      e ->
        {:error, {:exception, e, __STACKTRACE__}}
    end
  end

  defp prepare_input(input) when is_map(input) and not is_struct(input) do
    # Try to extract chat_message if present
    Map.get(input, :chat_message) || Map.get(input, "chat_message") || input
  end

  defp prepare_input(input) when is_binary(input) do
    %{chat_message: input}
  end

  defp prepare_input(input), do: input

  defp extract_result(response) when is_map(response) do
    # Return the full response map - don't extract just chat_message
    response
  end

  defp extract_result(response), do: response
end
