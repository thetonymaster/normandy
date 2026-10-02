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
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Coordination.{ParallelOrchestrator, SharedContext}

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
        aggregate_with_manager(coordinator.manager, worker_results, context)

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
      tasks
      |> Enum.map(fn %{worker_id: worker_id, task: task} ->
        worker = fetch_worker!(coordinator.workers, worker_id)
        %{id: worker_id, agent: worker.agent, input: task}
      end)
      |> unique_ids()

    # Execute workers
    {:ok, worker_results} =
      ParallelOrchestrator.execute(worker_specs, max_concurrency: max_concurrency)

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
    {_updated_manager, response} = BaseAgent.run(manager, input)

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
  # would keep only its last result. Number them ("w1#1", "w1#2"); a worker
  # with one task keeps its plain id.
  defp unique_ids(specs) do
    counts = Enum.frequencies_by(specs, & &1.id)

    {specs, _seen} =
      Enum.map_reduce(specs, %{}, fn spec, seen ->
        if counts[spec.id] > 1 do
          n = Map.get(seen, spec.id, 0) + 1
          {%{spec | id: "#{spec.id}##{n}"}, Map.put(seen, spec.id, n)}
        else
          {spec, seen}
        end
      end)

    specs
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
      {_updated_manager, response} = BaseAgent.run(manager, aggregation_input)

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

  defp result_text(result) when is_binary(result), do: result

  # BaseIOSchema's Any fallback renders "" and lists pass through unencoded, so
  # only use it where a real implementation exists.
  defp result_text(result) do
    if BaseIOSchema.impl_for(result) in [BaseIOSchema.Any, BaseIOSchema.List],
      do: inspect(result),
      else: BaseIOSchema.to_json(result)
  end

  defp failure_text({:exception, exception, _stacktrace}), do: Exception.message(exception)
  defp failure_text(reason), do: inspect(reason)
end
