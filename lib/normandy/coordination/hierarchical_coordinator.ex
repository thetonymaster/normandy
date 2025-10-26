defmodule Normandy.Coordination.HierarchicalCoordinator do
  @moduledoc """
  Coordinates hierarchical multi-agent systems with manager-worker patterns.

  The Hierarchical Coordinator implements a manager-worker pattern where
  a manager agent delegates tasks to worker agents and aggregates results.

  ## Example

      coordinator = HierarchicalCoordinator.new(
        manager: manager_agent,
        workers: [worker1, worker2, worker3],
        delegation_strategy: :round_robin
      )

      {:ok, result} = HierarchicalCoordinator.execute(
        coordinator,
        "Analyze this dataset",
        shared_context: context
      )
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{SharedContext, ParallelOrchestrator}

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

  @doc """
  Creates a new hierarchical coordinator.

  ## Options

  - `:manager` - Manager agent (required)
  - `:workers` - List of worker agents (required)
  - `:delegation_strategy` - How to delegate: `:round_robin`, `:broadcast`, `:conditional`
  - `:shared_context` - SharedContext to use (default: new context)

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
    %__MODULE__{
      manager: Keyword.fetch!(opts, :manager),
      workers: Keyword.fetch!(opts, :workers),
      delegation_strategy: Keyword.get(opts, :delegation_strategy, :round_robin),
      shared_context: Keyword.get(opts, :shared_context, SharedContext.new())
    }
  end

  @doc """
  Executes the hierarchical coordination.

  The manager agent analyzes the input and decides how to delegate work
  to worker agents.

  ## Options

  - `:shared_context` - Override coordinator's shared context
  - `:max_concurrency` - Max concurrent workers (default: 5)
  - `:manager_prompt` - Custom prompt for manager

  ## Example

      {:ok, result} = HierarchicalCoordinator.execute(
        coordinator,
        input,
        manager_prompt: "Break down this task for worker agents"
      )
  """
  @spec execute(t(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(%__MODULE__{} = coordinator, input, opts \\ []) do
    context = Keyword.get(opts, :shared_context, coordinator.shared_context)
    max_concurrency = Keyword.get(opts, :max_concurrency, 5)
    manager_prompt = Keyword.get(opts, :manager_prompt)

    # Step 1: Manager analyzes input and creates delegation plan
    manager_input = prepare_manager_input(input, manager_prompt)

    case execute_manager(coordinator.manager, manager_input, context) do
      {:ok, delegation_plan} ->
        # Step 2: Delegate to workers based on strategy
        worker_specs = create_worker_specs(coordinator, delegation_plan, input)

        # Step 3: Execute workers
        {:ok, worker_results} =
          ParallelOrchestrator.execute(worker_specs, max_concurrency: max_concurrency)

        # Step 4: Manager aggregates results
        aggregate_with_manager(
          coordinator.manager,
          worker_results.results,
          context
        )

      {:error, reason} ->
        {:error, {:manager_failed, reason}}
    end
  end

  @doc """
  Executes with explicit task delegation.

  Bypasses manager's delegation planning and directly assigns tasks to workers.

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
    max_concurrency = Keyword.get(opts, :max_concurrency, 5)
    context = Keyword.get(opts, :shared_context, coordinator.shared_context)

    # Map tasks to worker specs
    worker_specs =
      Enum.map(tasks, fn %{worker_id: worker_id, task: task} ->
        worker = Enum.find(coordinator.workers, fn w -> w.id == worker_id end)

        %{
          id: worker_id,
          agent: worker.agent,
          input: task
        }
      end)

    # Execute workers
    {:ok, worker_results} =
      ParallelOrchestrator.execute(worker_specs, max_concurrency: max_concurrency)

    # Aggregate with manager
    aggregate_with_manager(coordinator.manager, worker_results.results, context)
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

  defp prepare_manager_input(input, custom_prompt) do
    base_input = if is_binary(input), do: %{chat_message: input}, else: input

    if custom_prompt do
      Map.put(base_input, :manager_instruction, custom_prompt)
    else
      base_input
    end
  end

  defp execute_manager(manager, input, _context) do
    try do
      {_updated_manager, response} = BaseAgent.run(manager, input)

      # Extract delegation plan from response
      plan = extract_delegation_plan(response)
      {:ok, plan}
    rescue
      e ->
        {:error, {:exception, e, __STACKTRACE__}}
    end
  end

  defp extract_delegation_plan(response) when is_map(response) do
    # Try to extract structured plan
    Map.get(response, :delegation_plan) ||
      Map.get(response, :chat_message) ||
      response
  end

  defp extract_delegation_plan(response), do: response

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

  defp aggregate_with_manager(manager, results, _context) do
    # Manager aggregates worker results
    aggregation_input = %{
      chat_message: "Aggregate these results",
      worker_results: results
    }

    try do
      {_updated_manager, response} = BaseAgent.run(manager, aggregation_input)

      result =
        Map.get(response, :chat_message) ||
          Map.get(response, :aggregated_result) ||
          response

      {:ok, result}
    rescue
      e ->
        {:error, {:aggregation_failed, e, __STACKTRACE__}}
    end
  end
end
