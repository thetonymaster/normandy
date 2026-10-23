defmodule Normandy.DSL.Workflow.Runtime do
  @moduledoc false
  # What a workflow's generated execute/1 runs: the step loop, agent lookup and
  # the three step kinds. It lives here, not in the user's module, so a workflow
  # module holds only what differs per workflow: its steps, its transform and
  # when_result clauses (passed in as `transform` and `after_step`).

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.Reactive

  @type step :: %{
          required(:name) => atom(),
          required(:type) => :sequential | :parallel | :race,
          required(:agents) => [%{module: module(), name: term()}],
          required(:input) => term(),
          optional(atom()) => term()
        }

  @type state :: %{results: map(), current_input: term()}

  @doc """
  Runs `steps` in order. `transform` is the workflow's `(step_name, value -> value)`
  and `after_step` its `(step, state -> {:cont, {:ok, state}} | {:halt, {:error, _}})`.
  Returns `{:ok, results}` or `{:error, {step_name, reason}}`.
  """
  @spec run([step()], map(), term(), (atom(), term() -> term()), (step(), state() -> term())) ::
          {:ok, map()} | {:error, term()}
  def run(steps, agents_map, initial_input, transform, after_step) do
    initial_state = %{results: %{}, current_input: initial_input}

    steps
    |> Enum.reduce_while({:ok, initial_state}, fn step, {:ok, state} ->
      case execute_step(step, agents_map, state, transform) do
        {:ok, updated_state} -> after_step.(step, updated_state)
        {:error, reason} -> {:halt, {:error, {step.name, reason}}}
      end
    end)
    |> case do
      {:ok, final_state} -> {:ok, final_state.results}
      error -> error
    end
  end

  @doc "Records `value` as the result of step `name` and as the next step's default input."
  @spec put_step_result(state(), atom(), term()) :: state()
  def put_step_result(state, name, value),
    do: %{state | results: Map.put(state.results, name, value), current_input: value}

  defp execute_step(%{type: :sequential} = step, agents_map, state, transform) do
    with {:ok, input} <- step_input(step, state, transform),
         {:ok, agent} <- get_agent(step.agents, agents_map),
         {:ok, result} <- run_agent(agent, input) do
      {:ok, put_step_result(state, step.name, result)}
    end
  end

  defp execute_step(%{type: :parallel} = step, agents_map, state, transform) do
    with {:ok, input} <- step_input(step, state, transform),
         {:ok, agent_list} <- get_agents(step.agents, agents_map),
         {:ok, results} <- Reactive.all(agent_list, input) do
      {:ok, put_step_result(state, step.name, name_results(results, step.agents))}
    end
  end

  defp execute_step(%{type: :race} = step, agents_map, state, transform) do
    with {:ok, input} <- step_input(step, state, transform),
         {:ok, agent_list} <- get_agents(step.agents, agents_map),
         {:ok, result} <- Reactive.race(agent_list, input) do
      {:ok, put_step_result(state, step.name, result)}
    end
  end

  defp step_input(step, state, transform) do
    with {:ok, input} <- raw_step_input(step, state) do
      {:ok, transform.(step.name, input)}
    end
  end

  defp raw_step_input(%{input: [from: step_name]}, state) do
    case Map.get(state.results, step_name) do
      nil -> {:error, {:missing_step_result, step_name}}
      result -> {:ok, result}
    end
  end

  # No input: the previous step's result (or the initial input).
  defp raw_step_input(%{input: input}, state), do: {:ok, input || state.current_input}

  defp get_agent([%{module: module} | _], agents_map) do
    case Map.get(agents_map, module) do
      nil -> {:error, {:missing_agent, module}}
      agent -> {:ok, agent}
    end
  end

  defp get_agents(agent_infos, agents_map) do
    agent_infos
    |> Enum.reduce_while({:ok, []}, fn %{module: module}, {:ok, acc} ->
      case Map.get(agents_map, module) do
        nil -> {:halt, {:error, {:missing_agent, module}}}
        agent -> {:cont, {:ok, [agent | acc]}}
      end
    end)
    |> case do
      {:ok, agents} -> {:ok, Enum.reverse(agents)}
      error -> error
    end
  end

  # BaseAgent.run/2 returns Normandy's failures as {:error, exception} and raises
  # a bug; both become the step's {:error, exception} (the bug's stacktrace is
  # logged), the same shape a parallel or race step gets from Reactive.
  defp run_agent(agent, input) do
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, _updated_agent, response} -> {:ok, response}
      {:error, exception} -> {:error, exception}
    end
  rescue
    e -> Normandy.TurnError.log_raised("Workflow agent", e, __STACKTRACE__)
  end

  defp name_results(results, agent_infos) do
    agent_infos
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {%{name: name}, idx}, acc ->
      agent_key = "agent_#{idx}"
      result = Map.get(results, agent_key)

      if name do
        Map.put(acc, name, result)
      else
        Map.put(acc, String.to_atom(agent_key), result)
      end
    end)
  end

  defp prepare_input(input) when is_binary(input), do: %{chat_message: input}
  defp prepare_input(input) when is_map(input), do: input
  defp prepare_input(input), do: %{chat_message: to_string(input)}
end
