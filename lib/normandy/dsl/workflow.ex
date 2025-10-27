defmodule Normandy.DSL.Workflow do
  @moduledoc """
  DSL for defining multi-agent workflows with a declarative syntax.

  Provides macros to compose complex agent interactions in a readable,
  maintainable way.

  ## Examples

      defmodule ResearchWorkflow do
        use Normandy.DSL.Workflow

        workflow do
          # Sequential steps
          step :gather_sources do
            agent ResearchAgent
            input "Find sources about quantum computing"
          end

          step :analyze_sources do
            agent AnalysisAgent
            input from: :gather_sources
            transform fn sources -> "Analyze these: \#{sources}" end
          end

          # Parallel execution
          parallel :validate do
            agent FactCheckAgent, name: :fact_check
            agent QualityAgent, name: :quality_check
            input from: :analyze_sources
          end

          # Conditional execution
          step :final_review do
            agent ReviewAgent
            input from: :validate
            when_result do
              {:ok, %{quality: q}} when q > 0.8 -> :approve
              {:ok, _} -> :needs_revision
            end
          end
        end
      end

      # Execute the workflow
      {:ok, result} = ResearchWorkflow.execute(
        agents: %{
          ResearchAgent => research_agent,
          AnalysisAgent => analysis_agent
        },
        initial_input: "quantum computing"
      )

  ## Workflow Patterns

  ### Sequential Steps

      step :step1 do
        agent MyAgent
        input "some input"
      end

      step :step2 do
        agent AnotherAgent
        input from: :step1
      end

  ### Parallel Execution

      parallel :check do
        agent Agent1, name: :check1
        agent Agent2, name: :check2
        input "same input for all"
      end

  ### Conditional Execution

      step :process do
        agent MyAgent
        input from: :previous
        when_result do
          {:ok, value} when value > 10 -> :high
          {:ok, _} -> :low
        end
      end

  ### Race Pattern

      race :fastest do
        agent FastAgent1, name: :fast1
        agent FastAgent2, name: :fast2
        input "Who can answer fastest?"
      end

  ## Features

  - Sequential, parallel, and race execution
  - Data flow between steps
  - Conditional execution
  - Result transformation
  - Error handling
  - Compile-time workflow validation
  """

  alias Normandy.Coordination.{Reactive, SequentialOrchestrator, ParallelOrchestrator}

  defmacro __using__(_opts) do
    quote do
      import Normandy.DSL.Workflow
      Module.register_attribute(__MODULE__, :workflow_steps, accumulate: true)
      @before_compile Normandy.DSL.Workflow
    end
  end

  @doc """
  Defines a workflow block.
  """
  defmacro workflow(do: block) do
    quote do
      unquote(block)
    end
  end

  @doc """
  Defines a sequential step in the workflow.

  ## Options

  - `agent` - Agent module or instance to use
  - `input` - Input for the agent (string, or `from: :step_name`)
  - `transform` - Function to transform input from previous step
  - `when_result` - Conditional execution block
  """
  defmacro step(name, do: block) do
    quote do
      var!(current_step_name) = unquote(name)
      var!(current_step_type) = :sequential
      var!(current_step_agents) = []
      var!(current_step_input) = nil
      var!(current_step_transform) = nil
      var!(current_step_condition) = nil

      unquote(block)

      Module.put_attribute(__MODULE__, :workflow_steps, %{
        name: var!(current_step_name),
        type: var!(current_step_type),
        agents: Enum.reverse(var!(current_step_agents)),
        input: var!(current_step_input),
        transform: var!(current_step_transform),
        condition: var!(current_step_condition)
      })
    end
  end

  @doc """
  Defines a parallel execution step.

  All agents run concurrently with the same input.
  """
  defmacro parallel(name, do: block) do
    quote do
      var!(current_step_name) = unquote(name)
      var!(current_step_type) = :parallel
      var!(current_step_agents) = []
      var!(current_step_input) = nil
      var!(current_step_transform) = nil
      var!(current_step_condition) = nil

      unquote(block)

      Module.put_attribute(__MODULE__, :workflow_steps, %{
        name: var!(current_step_name),
        type: var!(current_step_type),
        agents: Enum.reverse(var!(current_step_agents)),
        input: var!(current_step_input),
        transform: var!(current_step_transform),
        condition: var!(current_step_condition)
      })
    end
  end

  @doc """
  Defines a race execution step.

  Returns the first successful result.
  """
  defmacro race(name, do: block) do
    quote do
      var!(current_step_name) = unquote(name)
      var!(current_step_type) = :race
      var!(current_step_agents) = []
      var!(current_step_input) = nil
      var!(current_step_transform) = nil
      var!(current_step_condition) = nil

      unquote(block)

      Module.put_attribute(__MODULE__, :workflow_steps, %{
        name: var!(current_step_name),
        type: var!(current_step_type),
        agents: Enum.reverse(var!(current_step_agents)),
        input: var!(current_step_input),
        transform: var!(current_step_transform),
        condition: var!(current_step_condition)
      })
    end
  end

  @doc """
  Specifies an agent for the current step.

  ## Options

  - `name:` - Optional name for this agent in parallel/race steps
  """
  defmacro agent(module, opts \\ []) do
    quote do
      agent_info = %{
        module: unquote(module),
        name: unquote(opts)[:name]
      }

      var!(current_step_agents) = [agent_info | var!(current_step_agents)]
    end
  end

  @doc """
  Specifies the input for the current step.

  Can be:
  - A string literal
  - `from: :step_name` to use output from another step
  - A map
  """
  defmacro input(value) do
    quote bind_quoted: [value: value] do
      var!(current_step_input) = value
    end
  end

  @doc """
  Transforms the input before passing to the agent.

  ## Examples

      transform fn prev_output ->
        "Process this: \#{prev_output}"
      end
  """
  defmacro transform(fun) do
    quote bind_quoted: [fun: fun] do
      var!(current_step_transform) = fun
    end
  end

  @doc """
  Conditional execution based on result.

  ## Examples

      when_result do
        {:ok, value} when value > 10 -> :continue
        {:ok, _} -> :stop
        {:error, _} -> :retry
      end
  """
  defmacro when_result(do: clauses) do
    quote do
      var!(current_step_condition) = fn result ->
        case result do
          unquote(clauses)
        end
      end
    end
  end

  defmacro __before_compile__(env) do
    # Get the steps at compile time
    steps =
      Module.get_attribute(env.module, :workflow_steps, [])
      |> Enum.reverse()

    quote do
      @doc """
      Executes the workflow.

      ## Options

      - `:agents` - Map of agent modules to instances
      - `:initial_input` - Initial input for the workflow
      - `:context` - Optional shared context map

      ## Examples

          {:ok, result} = MyWorkflow.execute(
            agents: %{MyAgent => agent_instance},
            initial_input: "start here"
          )
      """
      def execute(opts) do
        agents_map = Keyword.fetch!(opts, :agents)
        initial_input = Keyword.fetch!(opts, :initial_input)
        context = Keyword.get(opts, :context, %{})

        execute_workflow(unquote(Macro.escape(steps)), agents_map, initial_input, context)
      end

      @doc """
      Returns the workflow steps defined in this module.
      """
      def steps do
        unquote(Macro.escape(steps))
      end

      # Private functions

      defp execute_workflow(steps, agents_map, initial_input, context) do
        initial_state = %{
          results: %{},
          context: context,
          current_input: initial_input
        }

        Enum.reduce_while(steps, {:ok, initial_state}, fn step, {:ok, state} ->
          case execute_step(step, agents_map, state) do
            {:ok, updated_state} ->
              {:cont, {:ok, updated_state}}

            {:error, reason} ->
              {:halt, {:error, {step.name, reason}}}
          end
        end)
        |> case do
          {:ok, final_state} -> {:ok, final_state.results}
          error -> error
        end
      end

      defp execute_step(%{type: :sequential} = step, agents_map, state) do
        with {:ok, input} <- get_step_input(step, state),
             {:ok, agent} <- get_agent(step.agents, agents_map),
             {:ok, result} <- run_agent(agent, input) do
          updated_results = Map.put(state.results, step.name, result)
          updated_state = %{state | results: updated_results, current_input: result}

          {:ok, updated_state}
        end
      end

      defp execute_step(%{type: :parallel} = step, agents_map, state) do
        with {:ok, input} <- get_step_input(step, state),
             {:ok, agent_list} <- get_agents(step.agents, agents_map),
             {:ok, results} <- Reactive.all(agent_list, input) do
          # Convert agent results map to named results if names provided
          named_results = name_results(results, step.agents)
          updated_results = Map.put(state.results, step.name, named_results)
          updated_state = %{state | results: updated_results, current_input: named_results}

          {:ok, updated_state}
        end
      end

      defp execute_step(%{type: :race} = step, agents_map, state) do
        with {:ok, input} <- get_step_input(step, state),
             {:ok, agent_list} <- get_agents(step.agents, agents_map),
             {:ok, result} <- Reactive.race(agent_list, input) do
          updated_results = Map.put(state.results, step.name, result)
          updated_state = %{state | results: updated_results, current_input: result}

          {:ok, updated_state}
        end
      end

      defp get_step_input(step, state) do
        case step.input do
          nil ->
            {:ok, state.current_input}

          binary when is_binary(binary) ->
            {:ok, binary}

          [from: step_name] ->
            case Map.get(state.results, step_name) do
              nil -> {:error, {:missing_step_result, step_name}}
              result -> {:ok, maybe_transform(result, step.transform)}
            end

          value ->
            {:ok, maybe_transform(value, step.transform)}
        end
      end

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

      defp run_agent(agent, input) do
        case Normandy.Agents.BaseAgent.run(agent, prepare_input(input)) do
          {_updated_agent, response} -> {:ok, response}
          {:error, reason} -> {:error, reason}
        end
      end

      defp maybe_transform(value, nil), do: value

      defp maybe_transform(value, transform) when is_function(transform, 1) do
        transform.(value)
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
  end
end
