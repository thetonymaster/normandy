defmodule Normandy.Coordination.HierarchicalCoordinator do
  @moduledoc """
  Coordinates hierarchical multi-agent systems with manager-worker patterns.

  The Hierarchical Coordinator implements a manager-worker pattern where
  a manager agent delegates tasks to worker agents and aggregates results.

  ## Example

      coordinator = HierarchicalCoordinator.new(
        manager: manager_agent,
        workers: [
          %{id: "worker_1", agent: worker1},
          %{id: "worker_2", agent: worker2}
        ],
        delegation_strategy: :round_robin
      )

      {:ok, result} = HierarchicalCoordinator.execute(
        coordinator,
        "Analyze this dataset",
        shared_context: context
      )
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Coordination.{ParallelOrchestrator, SharedContext}
  alias Normandy.Options
  alias Normandy.OrchestrationError
  alias Normandy.Telemetry.WorkflowSpan

  @type delegation_strategy :: :round_robin | :broadcast | :conditional
  @type t :: %__MODULE__{
          manager: struct(),
          workers: [%{id: String.t(), agent: struct()}],
          delegation_strategy: delegation_strategy(),
          shared_context: SharedContext.t()
        }

  defstruct manager: nil,
            workers: [],
            delegation_strategy: :round_robin,
            shared_context: nil

  @new_opts_schema NimbleOptions.new!(
                     manager: [type: :any, required: true, doc: "The manager agent."],
                     workers: [
                       type: {:list, {:custom, Normandy.Options, :plain_map, []}},
                       required: true,
                       type_doc: "a list of `%{id: String.t(), agent: agent}` maps",
                       doc: "The workers, each `%{id: String.t(), agent: agent}`."
                     ],
                     delegation_strategy: [
                       type: {:in, [:round_robin, :broadcast, :conditional]},
                       default: :round_robin,
                       doc: "How the manager's plan is delegated."
                     ],
                     shared_context: [
                       type: {:struct, Normandy.Coordination.SharedContext},
                       doc: "The context the agents share (default: a new `SharedContext`)."
                     ]
                   )

  @execute_opts_schema NimbleOptions.new!(
                         shared_context: [
                           type: {:struct, Normandy.Coordination.SharedContext},
                           doc: "Overrides the coordinator's shared context for this run."
                         ],
                         max_concurrency: [
                           type: :pos_integer,
                           default: 5,
                           doc: "Workers run at once."
                         ],
                         manager_prompt: [
                           type: :string,
                           doc: "A prompt put before the input the manager gets."
                         ]
                       )

  @execute_with_tasks_opts_schema NimbleOptions.new!(
                                    Keyword.take(@execute_opts_schema.schema, [
                                      :shared_context,
                                      :max_concurrency
                                    ])
                                  )

  @doc """
  Creates a new hierarchical coordinator.

  ## Options

  #{Options.docs(@new_opts_schema)}

  ## Example

      coordinator = HierarchicalCoordinator.new(
        manager: manager_agent,
        workers: [
          %{id: "worker_1", agent: worker1},
          %{id: "worker_2", agent: worker2}
        ],
        delegation_strategy: :broadcast
      )
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})

    %__MODULE__{
      manager: Keyword.fetch!(opts, :manager),
      workers: Keyword.fetch!(opts, :workers),
      delegation_strategy: Keyword.fetch!(opts, :delegation_strategy),
      shared_context: Keyword.get_lazy(opts, :shared_context, &SharedContext.new/0)
    }
  end

  @doc """
  Executes the hierarchical coordination.

  The manager agent analyzes the input and decides how to delegate work
  to worker agents.

  ## Options

  #{Options.docs(@execute_opts_schema)}

  ## Example

      {:ok, result} = HierarchicalCoordinator.execute(
        coordinator,
        input,
        manager_prompt: "Break down this task for worker agents"
      )
  """
  @spec execute(t(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(%__MODULE__{} = coordinator, input, opts \\ []) do
    opts = Options.validate!(opts, @execute_opts_schema, {__MODULE__, :execute, 3})

    # step_count: the coordinator's workers (the delegation plan is not known yet).
    WorkflowSpan.span(:hierarchical, %{step_count: length(coordinator.workers)}, fn ->
      run_hierarchy(coordinator, input, opts)
    end)
  end

  defp run_hierarchy(coordinator, input, opts) do
    context = Keyword.get(opts, :shared_context, coordinator.shared_context)
    max_concurrency = Keyword.fetch!(opts, :max_concurrency)
    manager_prompt = Keyword.get(opts, :manager_prompt)

    # Step 1: Manager analyzes input and creates delegation plan
    manager_input = prepare_manager_input(input, manager_prompt)

    case execute_manager(coordinator.manager, manager_input, context) do
      {:ok, delegation_plan} ->
        # Step 2: Delegate to workers based on strategy
        worker_specs = create_worker_specs(coordinator, delegation_plan, input)

        # Step 3: Execute workers; failed workers are reported to the manager.
        worker_results =
          worker_specs
          |> ParallelOrchestrator.execute_specs(max_concurrency: max_concurrency)
          |> worker_outcome()

        # Step 4: Manager aggregates results
        aggregate_with_manager(coordinator.manager, worker_results, context)

      {:error, reason} ->
        {:error, {:manager_failed, reason}}
    end
  end

  @doc """
  Executes with explicit task delegation.

  Bypasses manager's delegation planning and directly assigns tasks to workers.

  ## Options

  #{Options.docs(@execute_with_tasks_opts_schema)}

  ## Example

      tasks = [
        %{worker_id: "worker_1", task: "Research topic A"},
        %{worker_id: "worker_2", task: "Research topic B"}
      ]

      {:ok, result} = HierarchicalCoordinator.execute_with_tasks(
        coordinator,
        tasks
      )
  """
  @spec execute_with_tasks(t(), [%{worker_id: String.t(), task: term()}], keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_with_tasks(%__MODULE__{} = coordinator, tasks, opts \\ []) do
    opts =
      Options.validate!(
        opts,
        @execute_with_tasks_opts_schema,
        {__MODULE__, :execute_with_tasks, 3}
      )

    WorkflowSpan.span(:hierarchical, %{step_count: length(tasks)}, fn ->
      run_tasks(coordinator, tasks, opts)
    end)
  end

  defp run_tasks(coordinator, tasks, opts) do
    max_concurrency = Keyword.fetch!(opts, :max_concurrency)
    context = Keyword.get(opts, :shared_context, coordinator.shared_context)

    # Map tasks to worker specs
    worker_specs =
      tasks
      |> Enum.map(fn %{worker_id: worker_id, task: task} ->
        worker = fetch_worker!(coordinator.workers, worker_id)
        %{id: worker_id, agent: worker.agent, input: task}
      end)
      |> unique_ids()

    # Execute workers
    worker_results =
      worker_specs
      |> ParallelOrchestrator.execute_specs(max_concurrency: max_concurrency)
      |> worker_outcome()

    # Aggregate with manager
    aggregate_with_manager(coordinator.manager, worker_results, context)
  end

  @doc """
  Adds a worker to the coordinator.

  ## Example

      coordinator = HierarchicalCoordinator.add_worker(
        coordinator,
        "new_worker",
        new_agent
      )
  """
  @spec add_worker(t(), String.t(), struct()) :: t()
  def add_worker(%__MODULE__{workers: workers} = coordinator, worker_id, agent) do
    new_worker = %{id: worker_id, agent: agent}
    %{coordinator | workers: workers ++ [new_worker]}
  end

  @doc """
  Removes a worker from the coordinator.

  ## Example

      coordinator = HierarchicalCoordinator.remove_worker(coordinator, "worker_1")
  """
  @spec remove_worker(t(), String.t()) :: t()
  def remove_worker(%__MODULE__{workers: workers} = coordinator, worker_id) do
    updated_workers = Enum.reject(workers, fn w -> w.id == worker_id end)
    %{coordinator | workers: updated_workers}
  end

  # Private functions

  # The input schema keeps only its own fields (chat_message by default), so the
  # manager prompt goes into chat_message rather than a key that would be dropped.
  defp prepare_manager_input(input, custom_prompt) do
    base_input = if is_binary(input), do: %{chat_message: input}, else: input

    if custom_prompt do
      Map.update(base_input, :chat_message, custom_prompt, fn
        nil -> custom_prompt
        message -> custom_prompt <> "\n\n" <> message
      end)
    else
      base_input
    end
  end

  defp execute_manager(manager, input, _context) do
    {_updated_manager, response} = BaseAgent.run!(manager, input)

    # Extract delegation plan from response
    plan = extract_delegation_plan(response)
    {:ok, plan}
  rescue
    e ->
      {:error, {:exception, e, __STACKTRACE__}}
  catch
    # An exit (a timed-out GenServer.call, say) is the manager's failure too.
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  defp extract_delegation_plan(response) when is_map(response) do
    # Try to extract structured plan
    Map.get(response, :delegation_plan) ||
      Map.get(response, :chat_message) ||
      response
  end

  defp create_worker_specs(coordinator, delegation_plan, original_input) do
    case coordinator.delegation_strategy do
      :round_robin ->
        create_round_robin_specs(coordinator.workers, delegation_plan)

      :broadcast ->
        create_broadcast_specs(coordinator.workers, original_input)

      :conditional ->
        create_conditional_specs(coordinator.workers, delegation_plan)
    end
  end

  defp create_round_robin_specs(workers, plan) when is_list(plan) do
    # Distribute tasks across workers in round-robin fashion
    workers
    |> Stream.cycle()
    |> Enum.zip(plan)
    |> Enum.map(fn {worker, task} ->
      %{
        id: worker.id,
        agent: worker.agent,
        input: task
      }
    end)
    |> unique_ids()
  end

  defp create_round_robin_specs(workers, plan) do
    # If plan is not a list, send to first worker
    [worker | _] = workers

    [
      %{
        id: worker.id,
        agent: worker.agent,
        input: plan
      }
    ]
  end

  defp create_broadcast_specs(workers, input) do
    # Send same input to all workers
    Enum.map(workers, fn worker ->
      %{
        id: worker.id,
        agent: worker.agent,
        input: input
      }
    end)
  end

  defp create_conditional_specs(workers, plan) when is_map(plan) do
    # Plan should contain worker assignments
    Enum.flat_map(workers, fn worker ->
      case Map.get(plan, worker.id) || Map.get(plan, String.to_atom(worker.id)) do
        nil ->
          []

        task ->
          [
            %{
              id: worker.id,
              agent: worker.agent,
              input: task
            }
          ]
      end
    end)
  end

  defp create_conditional_specs(workers, plan) do
    # Fallback to round-robin
    create_round_robin_specs(workers, plan)
  end

  # ParallelOrchestrator keys results by spec id, so a worker with several tasks
  # would keep only its last result. Number them ("w1#1", "w1#2"), skipping any
  # number that is another worker's id; a worker with one task keeps its plain id.
  defp unique_ids(specs) do
    counts = Enum.frequencies_by(specs, & &1.id)
    taken = MapSet.new(specs, & &1.id)

    {specs, _state} =
      Enum.map_reduce(specs, {%{}, taken}, fn spec, {seen, taken} ->
        if counts[spec.id] > 1 do
          {id, n} = next_free_id(spec.id, Map.get(seen, spec.id, 0) + 1, taken)
          {%{spec | id: id}, {Map.put(seen, spec.id, n), MapSet.put(taken, id)}}
        else
          {spec, {seen, taken}}
        end
      end)

    specs
  end

  defp next_free_id(base, n, taken) do
    id = "#{base}##{n}"
    if MapSet.member?(taken, id), do: next_free_id(base, n + 1, taken), else: {id, n}
  end

  defp fetch_worker!(workers, worker_id) do
    Enum.find(workers, fn w -> w.id == worker_id end) ||
      raise ArgumentError,
            "HierarchicalCoordinator.execute_with_tasks/3: no worker #{inspect(worker_id)}; " <>
              "workers are #{inspect(Enum.map(workers, & &1.id))}"
  end

  defp aggregate_with_manager(manager, worker_results, _context) do
    # Results travel as text in chat_message: an input schema drops any other key.
    aggregation_input = %{chat_message: aggregation_message(worker_results)}

    try do
      {_updated_manager, response} = BaseAgent.run!(manager, aggregation_input)

      result =
        Map.get(response, :chat_message) ||
          Map.get(response, :aggregated_result) ||
          response

      {:ok, result}
    rescue
      e ->
        {:error, {:aggregation_failed, e, __STACKTRACE__}}
    catch
      :exit, reason ->
        {:error, {:aggregation_failed, {:exit, reason}}}
    end
  end

  defp aggregation_message(%{results: results, errors: errors}) do
    succeeded =
      results
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, result} -> "## #{id}\n#{result_text(result)}" end)

    failed =
      errors
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, reason} -> "## #{id} (failed)\n#{failure_text(reason)}" end)

    Enum.join(["Aggregate these worker results:" | succeeded ++ failed], "\n\n")
  end

  # The workers' outputs and failures, whichever way execute_specs/2 returned.
  defp worker_outcome({:ok, results}), do: %{results: results, errors: %{}}

  defp worker_outcome({:error, %OrchestrationError{results: results, errors: errors}}),
    do: %{results: results, errors: errors}

  defp result_text(result) when is_binary(result), do: result

  # BaseIOSchema's Any fallback renders "" and lists pass through unencoded, so
  # only use it where a real implementation exists.
  defp result_text(result) do
    if BaseIOSchema.impl_for(result) in [BaseIOSchema.Any, BaseIOSchema.List],
      do: inspect(result),
      else: BaseIOSchema.to_json(result)
  end

  defp failure_text(exception), do: Exception.message(exception)
end
