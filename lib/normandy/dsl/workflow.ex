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
            transform fn %{chat_message: sources} -> "Analyze these: " <> sources end
          end

          # Parallel execution
          parallel :validate do
            agent FactCheckAgent, name: :fact_check
            agent QualityAgent, name: :quality_check
            input from: :analyze_sources
            transform fn %{chat_message: analysis} -> analysis end
          end

          # Conditional execution: the clause's value becomes the step result. A
          # parallel step's result maps each agent's name to its {:ok, answer} or
          # {:error, exception}.
          step :final_review do
            agent ReviewAgent
            input from: :validate
            transform fn %{fact_check: {:ok, facts}, quality_check: {:ok, quality}} ->
              "Facts: " <> facts.chat_message <> "\\nQuality: " <> quality.chat_message
            end
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

  `when_result` works like `Normandy.Coordination.Reactive.when_result/3`: it runs
  after the step, matches `{:ok, result}`, and the matching clause's value becomes
  the step's result (what later steps and `from:` see). `{:ok, value}` gives
  `value`, `{:error, reason}` fails the workflow as `{:error, {step_name, reason}}`,
  and any other value is the result as it is. A clause can run another agent.

      step :process do
        agent MyAgent
        input from: :previous
        when_result do
          {:ok, %{chat_message: "REJECT" <> _}} -> {:error, :rejected}
          {:ok, %{confidence: c}} when c < 0.5 -> :low_confidence
          {:ok, result} -> {:ok, result}
        end
      end

  A blank answer never reaches `when_result`: the agent's run already failed with
  `%Normandy.LLMError{type: :invalid_output}`, so the workflow returns
  `{:error, {step_name, %Normandy.LLMError{}}}`.

  ### Transforming Input

  `transform` receives the step's input (a literal, a `from:` result, or the
  previous step's result) and returns what the agent gets.

      step :summarize do
        agent Summarizer
        input from: :research
        transform fn %{chat_message: text} -> "Summarize: " <> text end
      end

  ### Race Pattern

      race :fastest do
        agent FastAgent1, name: :fast1
        agent FastAgent2, name: :fast2
        input "Who can answer fastest?"
      end

  ## Telemetry

  `execute/1` runs under a `[:normandy, :workflow, :run]` span (`:start`, `:stop`,
  `:exception`) with metadata `:workflow_name` (the module), `:orchestrator`
  (`:workflow`) and `:step_count`. Agent runs started by the workflow's steps
  nest under it, so a trace shows workflow -> run -> llm_call/tool. The
  orchestrators in `Normandy.Coordination` emit the same span from their own
  entry points (see `Normandy.Telemetry.WorkflowSpan`); `Reactive`'s combinators
  are building blocks used inside this span and emit none of their own (a current
  limitation).

  ## Features

  - Sequential, parallel, and race execution
  - Data flow between steps
  - Conditional execution
  - Result transformation
  - Error handling
  - Compile-time workflow validation: duplicate step names, steps without an
    agent, and `from:` references to unknown or later steps raise at compile time
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.Reactive
  alias Normandy.Options
  alias Normandy.Telemetry.WorkflowSpan

  @execute_opts_schema NimbleOptions.new!(
                         agents: [
                           type: {:custom, Normandy.Options, :plain_map, []},
                           required: true,
                           type_doc: "a map of agent module to agent config",
                           doc: "Each step's agent module mapped to its agent config."
                         ],
                         initial_input: [
                           type: :any,
                           required: true,
                           doc: "The first step's input."
                         ],
                         context: [
                           type: {:custom, Normandy.Options, :plain_map, []},
                           type_doc: "`t:map/0`",
                           default: %{},
                           doc: "A context map the steps share."
                         ]
                       )

  @execute_doc """
  Executes the workflow.

  ## Options

  #{Options.docs(@execute_opts_schema)}
  ## Examples

      {:ok, result} = MyWorkflow.execute(
        agents: %{MyAgent => agent_instance},
        initial_input: "start here"
      )
  """

  @doc false
  # Called by every workflow's generated execute/1, so the error names that module.
  @spec __validate_execute_opts__(keyword(), module()) :: keyword()
  def __validate_execute_opts__(opts, workflow),
    do: Options.validate!(opts, @execute_opts_schema, {workflow, :execute, 1})

  @doc false
  # A step's when_result value, applied to the workflow's state (see "Conditional
  # Execution"). Here and not in the generated module: there the compiler sees which
  # values that workflow's clauses return, and warns in the user's module about the
  # branches they never reach (a workflow whose clauses never return {:error, _}).
  @spec __after_condition__(atom(), map(), term()) ::
          {:cont, {:ok, map()}} | {:halt, {:error, {atom(), term()}}}
  def __after_condition__(step_name, _state, {:error, reason}),
    do: {:halt, {:error, {step_name, reason}}}

  def __after_condition__(step_name, state, {:ok, value}),
    do: {:cont, {:ok, put_step_result(state, step_name, value)}}

  def __after_condition__(step_name, state, value),
    do: {:cont, {:ok, put_step_result(state, step_name, value)}}

  defp put_step_result(state, name, value),
    do: %{state | results: Map.put(state.results, name, value), current_input: value}

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
  - `transform` - Function applied to the step's input before the agent runs
  - `when_result` - Clauses on `{:ok, result}` whose value becomes the step result
  """
  defmacro step(name, do: block) do
    quote do
      var!(current_step_name) = unquote(name)
      var!(current_step_type) = :sequential
      var!(current_step_agents) = []
      var!(current_step_input) = nil
      var!(current_step_transform) = nil
      var!(current_step_condition) = nil
      # The block may overwrite these before they are read.
      _ = {var!(current_step_input), var!(current_step_transform), var!(current_step_condition)}

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
      # The block may overwrite these before they are read.
      _ = {var!(current_step_input), var!(current_step_transform), var!(current_step_condition)}

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
      # The block may overwrite these before they are read.
      _ = {var!(current_step_input), var!(current_step_transform), var!(current_step_condition)}

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
  Transforms the step's input before passing it to the agent. Applies to every
  kind of input: a literal, a `from:` result, or the previous step's result.

  ## Examples

      transform fn prev_output ->
        "Process this: \#{prev_output}"
      end
  """
  defmacro transform(fun) do
    # Keep the function as code: a function value can't be escaped into the
    # generated execute/1, so __before_compile__ turns this into a defp clause.
    quote do
      var!(current_step_transform) = unquote(Macro.escape(fun))
    end
  end

  @doc """
  Replaces the step's result with the value of the clause matching
  `{:ok, result}`, like `Normandy.Coordination.Reactive.when_result/3`.

  `{:ok, value}` makes `value` the result, `{:error, reason}` fails the workflow,
  and any other value becomes the result as it is.

  ## Examples

      when_result do
        {:ok, %{chat_message: "REJECT" <> _}} -> {:error, :rejected}
        {:ok, %{confidence: c}} when c < 0.5 -> :low_confidence
        {:ok, result} -> {:ok, result}
      end

  A blank answer fails the step before `when_result` runs (see "Conditional Execution"
  in the moduledoc).
  """
  defmacro when_result(do: clauses) do
    fun =
      quote do
        fn result ->
          case result do
            unquote(clauses)
          end
        end
      end

    quote do
      var!(current_step_condition) = unquote(Macro.escape(fun))
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defmacro __before_compile__(env) do
    # Get the steps at compile time
    steps =
      Module.get_attribute(env.module, :workflow_steps, [])
      |> Enum.reverse()

    validate_steps!(steps)

    transform_clauses =
      for %{name: name, transform: fun} <- steps, fun != nil do
        quote do
          defp __workflow_transform__(unquote(name), value), do: unquote(fun).(value)
        end
      end

    condition_clauses =
      case for(%{name: name, condition: fun} <- steps, fun != nil, do: {name, fun}) do
        [] ->
          []

        conditions ->
          clauses =
            for {name, fun} <- conditions do
              quote do
                defp __workflow_condition__(unquote(name), result), do: unquote(fun).(result)
              end
            end

          # Steps without a when_result keep their result.
          fallback =
            quote do
              defp __workflow_condition__(_step, {:ok, result}), do: {:ok, result}
            end

          clauses ++ [fallback]
      end

    # when_result works like Reactive.when_result/3: the matching clause's value
    # becomes the step's result. {:ok, value} gives value, {:error, reason} fails
    # the workflow, any other value is the result as it is. Without any
    # when_result, the step result stands.
    after_step =
      if condition_clauses == [] do
        quote do
          defp after_step(_step, state), do: {:cont, {:ok, state}}
        end
      else
        quote do
          defp after_step(step, state) do
            result = Map.fetch!(state.results, step.name)

            unquote(__MODULE__).__after_condition__(
              step.name,
              state,
              __workflow_condition__(step.name, {:ok, result})
            )
          end
        end
      end

    # The code lives in the defp clauses above; the step data keeps only flags.
    steps =
      Enum.map(steps, fn step ->
        %{step | transform: step.transform != nil, condition: step.condition != nil}
      end)

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      @doc unquote(@execute_doc)
      def execute(opts) do
        opts = unquote(__MODULE__).__validate_execute_opts__(opts, __MODULE__)
        agents_map = Keyword.fetch!(opts, :agents)
        initial_input = Keyword.fetch!(opts, :initial_input)
        context = Keyword.fetch!(opts, :context)

        steps = unquote(Macro.escape(steps))

        # No content in the metadata: only the workflow's identity and size.
        metadata = %{workflow_name: __MODULE__, step_count: length(steps)}

        WorkflowSpan.span(:workflow, metadata, fn ->
          execute_workflow(steps, agents_map, initial_input, context)
        end)
      end

      @doc """
      Returns the workflow steps defined in this module.
      """
      def steps do
        unquote(Macro.escape(steps))
      end

      # Private functions

      unquote_splicing(transform_clauses)
      defp __workflow_transform__(_step, value), do: value

      unquote_splicing(condition_clauses)

      defp execute_workflow(steps, agents_map, initial_input, context) do
        initial_state = %{
          results: %{},
          context: context,
          current_input: initial_input
        }

        Enum.reduce_while(steps, {:ok, initial_state}, fn step, {:ok, state} ->
          case execute_step(step, agents_map, state) do
            {:ok, updated_state} -> after_step(step, updated_state)
            {:error, reason} -> {:halt, {:error, {step.name, reason}}}
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

      unquote(after_step)

      defp get_step_input(step, state) do
        with {:ok, input} <- raw_step_input(step, state) do
          {:ok, __workflow_transform__(step.name, input)}
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
  end

  defp validate_steps!(steps) do
    _earlier =
      Enum.reduce(steps, MapSet.new(), fn step, earlier ->
        validate_step!(step, earlier)
        MapSet.put(earlier, step.name)
      end)

    :ok
  end

  defp validate_step!(step, earlier) do
    if MapSet.member?(earlier, step.name) do
      raise ArgumentError, "workflow step #{inspect(step.name)} is defined more than once"
    end

    if step.agents == [] do
      raise ArgumentError, "workflow step #{inspect(step.name)} has no agent"
    end

    validate_source!(step, earlier)
  end

  defp validate_source!(%{name: name, input: [from: source]}, earlier) do
    unless MapSet.member?(earlier, source) do
      raise ArgumentError,
            "workflow step #{inspect(name)} takes input from #{inspect(source)}, " <>
              "which is not an earlier step"
    end
  end

  defp validate_source!(_step, _earlier), do: :ok
end
