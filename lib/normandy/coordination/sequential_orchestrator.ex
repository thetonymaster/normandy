defmodule Normandy.Coordination.SequentialOrchestrator do
  alias Normandy.Coordination.{AgentMessage, Orchestration}
  alias Normandy.Telemetry.WorkflowSpan

  @opts_schema NimbleOptions.new!(
                 on_agent_complete: [
                   type: {:fun, 2},
                   doc:
                     "`fn agent_id, output -> any end`, called after each agent that " <>
                       "succeeds (after `:transform`)."
                 ],
                 on_error: [
                   type: {:in, [:stop, :continue]},
                   default: :stop,
                   doc:
                     "`:stop` ends the pipeline at the first failure. `:continue` runs the " <>
                       "remaining agents, the next one receiving the last successful output " <>
                       "(or `input`). Either way a failure makes the result " <>
                       "`{:error, %Normandy.OrchestrationError{}}`."
                 ]
               )

  @messages_opts_schema NimbleOptions.new!([])

  @spec_keys [:id, :agent, :transform]

  @moduledoc """
  Runs agents one after another, each on the previous agent's output.

      {:ok, results} =
        SequentialOrchestrator.execute(
          [
            %{id: "research", agent: research_agent, transform: &extract_data/1},
            %{id: "write", agent: writing_agent}
          ],
          "Summarize the 2026 Elixir survey"
        )

      results["write"]

  `agents` holds `%Normandy.Agents.BaseAgentConfig{}` structs (keyed `"agent_0"`,
  `"agent_1"`, ... in list order) or specs `%{id: id, agent: config}` with an optional
  `:transform` (`fn output -> term end`): what it returns is the agent's result and the
  next agent's input. The first agent receives `input`.

  ## Results

  `{:ok, %{id => output}}` when every agent succeeded; the pipeline's output is the last
  agent's. Otherwise `{:error, %Normandy.OrchestrationError{}}` with the outputs of the
  agents that succeeded and the exception of each that failed. With `on_error: :stop`
  the agents after the failure did not run and are in neither map.
  """

  @doc """
  Runs `agents` in order, the first on `input`; see "Results".

  ## Options

  #{Normandy.Options.docs(@opts_schema)}
  """
  @spec execute([Orchestration.agent()], term(), keyword()) :: Orchestration.result()
  def execute(agents, input, opts \\ []) do
    opts = Normandy.Options.validate!(opts, @opts_schema, {__MODULE__, :execute, 3})
    specs = Orchestration.specs!(agents, @spec_keys, "#{inspect(__MODULE__)}.execute/3")

    WorkflowSpan.span(:sequential, %{step_count: length(specs)}, fn ->
      Orchestration.with_task_supervisor(&run_pipeline(&1, specs, input, opts))
    end)
  end

  defp run_pipeline(supervisor, specs, input, opts) do
    {_last_input, results, errors} =
      Enum.reduce_while(specs, {input, %{}, %{}}, &step(supervisor, &1, &2, opts))

    Orchestration.result(results, errors)
  end

  # One agent. Its output feeds the next agent; a failure ends the pipeline or, with
  # on_error: :continue, leaves the next agent the last successful output.
  # The agent runs in an unlinked task, so a crash in a process it linked to fails that
  # agent, not the caller. :transform and :on_agent_complete run in the caller, guarded as
  # in ParallelOrchestrator: a raise, exit or throw in either is that agent's error.
  defp step(supervisor, spec, {input, results, errors}, opts) do
    with {:ok, output} <-
           Orchestration.run_agent_isolated(supervisor, spec.id, spec.agent, input),
         {:ok, output} <-
           Orchestration.guard(spec.id, fn ->
             Orchestration.run_callbacks(spec, output, opts[:on_agent_complete])
           end) do
      {:cont, {output, Map.put(results, spec.id, output), errors}}
    else
      {:error, exception} ->
        acc = {input, results, Map.put(errors, spec.id, exception)}
        halt_or_continue(Keyword.fetch!(opts, :on_error), acc)
    end
  end

  defp halt_or_continue(:stop, acc), do: {:halt, acc}
  defp halt_or_continue(:continue, acc), do: {:cont, acc}

  @doc """
  Runs agent specs with message-based communication. Each agent receives the previous
  `AgentMessage`'s payload and answers with a reply, or an error message whose payload
  `:error` is the exception's message. Takes no options.

  ## Example

      {:ok, messages} = SequentialOrchestrator.execute_with_messages(specs, initial_message)
  """
  @spec execute_with_messages([Orchestration.spec()], AgentMessage.t(), keyword()) ::
          {:ok, [AgentMessage.t()]}
  def execute_with_messages(agent_specs, initial_message, opts \\ []) do
    _ =
      Normandy.Options.validate!(
        opts,
        @messages_opts_schema,
        {__MODULE__, :execute_with_messages, 3}
      )

    # The same spec check as execute/3: an unknown key or a bad agent raises ArgumentError
    # here, not a FunctionClauseError mid-pipeline.
    specs =
      Orchestration.specs!(
        agent_specs,
        [:id, :agent],
        "#{inspect(__MODULE__)}.execute_with_messages/3"
      )

    WorkflowSpan.span(:sequential, %{step_count: length(specs)}, fn ->
      run_with_messages(specs, initial_message)
    end)
  end

  defp run_with_messages(agent_specs, initial_message) do
    messages =
      Enum.reduce(agent_specs, [initial_message], fn spec, [current_msg | _] = acc ->
        agent_id = Map.fetch!(spec, :id)
        agent = Map.fetch!(spec, :agent)

        # Pattern match to validate struct type
        %AgentMessage{} = current_msg

        request_msg = %{current_msg | to: agent_id, type: "request"}

        case Orchestration.run_agent("Agent #{inspect(agent_id)}", agent, request_msg.payload) do
          {:ok, result} ->
            [AgentMessage.reply(request_msg, result) | acc]

          {:error, exception} ->
            [AgentMessage.error(request_msg, Exception.message(exception)) | acc]
        end
      end)

    {:ok, Enum.reverse(messages)}
  end
end
