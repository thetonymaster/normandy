defmodule Normandy.Coordination.SequentialOrchestrator do
  @moduledoc """
  Orchestrates sequential execution of multiple agents.

  The Sequential Orchestrator runs agents one after another, passing the
  output of one agent as input to the next. This creates a pipeline
  where each agent builds upon the work of previous agents.

  ## Example

      # Define agents
      agents = [
        %{id: "research", agent: research_agent, transform: &extract_data/1},
        %{id: "analyze", agent: analysis_agent, transform: &format_analysis/1},
        %{id: "write", agent: writing_agent}
      ]

      # Execute pipeline
      {:ok, result} = SequentialOrchestrator.execute(
        agents,
        initial_input,
        shared_context: context
      )
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{AgentMessage, SharedContext}

  @type agent_spec :: %{
          required(:id) => String.t(),
          required(:agent) => struct(),
          optional(:transform) => (term() -> term())
        }

  @type execution_result :: %{
          success: boolean(),
          results: [term()],
          errors: [term()],
          context: SharedContext.t()
        }

  @doc """
  Executes agents sequentially in a pipeline.

  ## Options

  - `:shared_context` - SharedContext to use (default: new context)
  - `:on_agent_complete` - Callback after each agent: `(agent_id, result, context -> any)`
  - `:on_error` - Error handling: `:stop` (default) or `:continue`
  - `:store_intermediate` - Store each result in shared context (default: true)

  ## Example

      {:ok, result} = SequentialOrchestrator.execute(
        agents,
        initial_input,
        shared_context: context,
        on_agent_complete: fn agent_id, _result, _ctx ->
          IO.puts("Agent \#{agent_id} completed")
        end
      )
  """
  @spec execute([agent_spec()], term(), keyword()) :: {:ok, execution_result()} | {:error, term()}
  def execute(agent_specs, initial_input, opts \\ []) when is_list(agent_specs) do
    context = Keyword.get(opts, :shared_context, SharedContext.new())
    on_complete = Keyword.get(opts, :on_agent_complete)
    on_error_strategy = Keyword.get(opts, :on_error, :stop)
    store_intermediate = Keyword.get(opts, :store_intermediate, true)

    # Execute pipeline
    result =
      Enum.reduce_while(agent_specs, {:ok, initial_input, context, []}, fn spec,
                                                                           {:ok, input, ctx,
                                                                            results} ->
        agent_id = Map.fetch!(spec, :id)
        agent = Map.fetch!(spec, :agent)
        transform_fn = Map.get(spec, :transform, & &1)

        # Execute agent
        case execute_agent(agent, input) do
          {:ok, agent_result} ->
            # Transform result if function provided
            transformed_result = transform_fn.(agent_result)

            # Store in context if enabled
            updated_ctx =
              if store_intermediate do
                SharedContext.put(ctx, {"results", agent_id}, transformed_result)
              else
                ctx
              end

            # Call completion callback if provided
            if on_complete do
              on_complete.(agent_id, transformed_result, updated_ctx)
            end

            # Continue to next agent with transformed result
            {:cont, {:ok, transformed_result, updated_ctx, results ++ [transformed_result]}}

          {:error, reason} ->
            error_result = %{agent_id: agent_id, error: reason, input: input}

            case on_error_strategy do
              :stop ->
                {:halt, {:error, error_result, ctx, results}}

              :continue ->
                # Continue with error as result
                {:cont, {:ok, {:error, reason}, ctx, results ++ [{:error, reason}]}}
            end
        end
      end)

    case result do
      {:ok, _final_input, context, results} ->
        {:ok,
         %{
           success: true,
           results: results,
           errors: [],
           context: context
         }}

      {:error, error, context, results} ->
        {:error,
         %{
           success: false,
           results: results,
           errors: [error],
           context: context
         }}
    end
  end

  @doc """
  Executes agents with message-based communication.

  Each agent receives an AgentMessage and returns an AgentMessage response.

  ## Example

      messages = SequentialOrchestrator.execute_with_messages(
        agents,
        initial_message,
        shared_context: context
      )
  """
  @spec execute_with_messages([agent_spec()], AgentMessage.t(), keyword()) ::
          {:ok, [AgentMessage.t()]} | {:error, term()}
  def execute_with_messages(agent_specs, initial_message, opts \\ []) do
    context = Keyword.get(opts, :shared_context, SharedContext.new())

    messages =
      Enum.reduce(agent_specs, [initial_message], fn spec, [current_msg | _] = acc ->
        agent_id = Map.fetch!(spec, :id)
        agent = Map.fetch!(spec, :agent)

        # Create request message for this agent
        request_msg = %AgentMessage{
          current_msg
          | to: agent_id,
            type: "request"
        }

        # Execute agent with message payload
        case execute_agent(agent, request_msg.payload) do
          {:ok, result} ->
            # Create response message
            response_msg = AgentMessage.reply(request_msg, result)
            [response_msg | acc]

          {:error, reason} ->
            # Create error message
            error_msg = AgentMessage.error(request_msg, inspect(reason))
            [error_msg | acc]
        end
      end)

    {:ok, Enum.reverse(messages)}
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
    # Try to extract the relevant result
    Map.get(response, :chat_message) ||
      Map.get(response, "chat_message") ||
      response
  end

  defp extract_result(response), do: response
end
