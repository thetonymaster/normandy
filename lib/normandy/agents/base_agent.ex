defmodule Normandy.Agents.BaseAgent do
  @moduledoc """
  Core agent implementation providing conversational AI capabilities.

  BaseAgent manages agent state, memory, and LLM interactions through a
  stateful configuration approach.
  """

  alias Normandy.Components.SystemPromptGenerator
  alias Normandy.Components.Message
  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.AgentMemory
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.BaseAgentConfig

  alias Normandy.Tools.Registry

  @type config_input :: %{
          required(:client) => struct(),
          required(:model) => String.t(),
          required(:temperature) => float(),
          optional(:input_schema) => struct(),
          optional(:output_schema) => struct(),
          optional(:memory) => map(),
          optional(:prompt_specification) => PromptSpecification.t(),
          optional(:max_tokens) => pos_integer() | nil,
          optional(:tool_registry) => Registry.t(),
          optional(:max_tool_iterations) => pos_integer()
        }

  @spec init(config_input()) :: BaseAgentConfig.t()
  def init(config) do
    %BaseAgentConfig{
      input_schema: Map.get(config, :input_schema, nil) || %BaseAgentInputSchema{},
      output_schema: Map.get(config, :output_schema, nil) || %BaseAgentOutputSchema{},
      memory: Map.get(config, :memory, nil) || AgentMemory.new_memory(),
      initial_memory: Map.get(config, :memory, nil) || AgentMemory.new_memory(),
      prompt_specification: Map.get(config, :prompt_specification) || %PromptSpecification{},
      client: config.client,
      model: config.model,
      current_user_input: nil,
      temperature: config.temperature,
      max_tokens: Map.get(config, :max_tokens, nil),
      tool_registry: Map.get(config, :tool_registry, nil),
      max_tool_iterations: Map.get(config, :max_tool_iterations, 5)
    }
  end

  @spec reset_memory(BaseAgentConfig.t()) :: BaseAgentConfig.t()
  def reset_memory(config = %BaseAgentConfig{initial_memory: memory}) do
    Map.put(config, :memory, memory)
  end

  @spec get_response(BaseAgentConfig.t(), struct() | nil) :: struct()
  def get_response(
        config = %BaseAgentConfig{prompt_specification: prompt_specification},
        response_model \\ nil
      ) do
    response_model =
      if response_model != nil do
        response_model
      else
        Map.get(config, :output_schema)
      end

    messages =
      [
        %Message{
          role: "system",
          content:
            SystemPromptGenerator.generate_prompt(prompt_specification, config.tool_registry)
        }
      ] ++ AgentMemory.history(config.memory)

    # Prepare tool schemas if tools are available
    opts =
      if has_tools?(config) do
        tool_schemas = Registry.to_tool_schemas(config.tool_registry)
        [tools: tool_schemas]
      else
        []
      end

    Normandy.Agents.Model.converse(
      config.client,
      config.model,
      config.temperature,
      config.max_tokens,
      messages,
      response_model,
      opts
    )
  end

  @spec run(BaseAgentConfig.t(), struct() | nil) :: {BaseAgentConfig.t(), struct()}
  def run(
        config = %BaseAgentConfig{memory: memory, output_schema: output_schema},
        user_input \\ nil
      ) do
    {config, memory} =
      if user_input != nil do
        updated_memory =
          memory
          |> AgentMemory.initialize_turn()
          |> AgentMemory.add_message("user", user_input)

        updated_config =
          config
          |> Map.put(:current_user_input, user_input)
          |> Map.put(:memory, updated_memory)

        {updated_config, updated_memory}
      else
        {config, memory}
      end

    response = get_response(config, output_schema)
    memory = AgentMemory.add_message(memory, "assistant", response)

    config = Map.put(config, :memory, memory)

    {config, response}
  end

  @doc """
  Run the agent with tool calling support.

  This method handles the full tool execution loop:
  1. Send user input to LLM
  2. If LLM requests tool calls, execute them
  3. Send tool results back to LLM
  4. Repeat until LLM provides final response or max iterations reached

  ## Parameters
    - config: Agent configuration
    - user_input: Optional user input to start the conversation

  ## Returns
    Tuple of {updated_config, final_response}

  ## Examples

      iex> {config, response} = BaseAgent.run_with_tools(agent, user_input)

  """
  @spec run_with_tools(BaseAgentConfig.t(), struct() | nil) ::
          {BaseAgentConfig.t(), struct()}
  def run_with_tools(
        config = %BaseAgentConfig{memory: memory, max_tool_iterations: max_iterations},
        user_input \\ nil
      ) do
    # Initialize turn with user input if provided
    memory =
      if user_input != nil do
        memory
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", user_input)
      else
        memory
      end

    config =
      if user_input != nil do
        config
        |> Map.put(:current_user_input, user_input)
        |> Map.put(:memory, memory)
      else
        config
      end

    # Execute tool loop
    execute_tool_loop(config, max_iterations)
  end

  # Private function to handle the tool execution loop
  defp execute_tool_loop(config, iterations_left) when iterations_left <= 0 do
    # Max iterations reached, return current state
    response = get_response(config, config.output_schema)
    memory = AgentMemory.add_message(config.memory, "assistant", response)
    config = Map.put(config, :memory, memory)
    {config, response}
  end

  defp execute_tool_loop(config, iterations_left) do
    alias Normandy.Agents.ToolCallResponse
    alias Normandy.Components.ToolResult
    alias Normandy.Tools.Executor

    # Get response from LLM (may include tool calls)
    response = get_response(config, %ToolCallResponse{})

    cond do
      # No tool calls - final response
      is_nil(response.tool_calls) or length(response.tool_calls) == 0 ->
        memory = AgentMemory.add_message(config.memory, "assistant", response)
        config = Map.put(config, :memory, memory)
        {config, response}

      # Has tool calls - execute them
      true ->
        # Add assistant message with tool calls to memory
        memory = AgentMemory.add_message(config.memory, "assistant", response)

        # Execute each tool call
        tool_results =
          Enum.map(response.tool_calls, fn tool_call ->
            case Executor.execute(config.tool_registry, tool_call.name) do
              {:ok, result} ->
                %ToolResult{
                  tool_call_id: tool_call.id,
                  output: result,
                  is_error: false
                }

              {:error, error} ->
                %ToolResult{
                  tool_call_id: tool_call.id,
                  output: %{error: error},
                  is_error: true
                }
            end
          end)

        # Add tool results to memory
        memory =
          Enum.reduce(tool_results, memory, fn result, mem ->
            AgentMemory.add_message(mem, "tool", result)
          end)

        config = Map.put(config, :memory, memory)

        # Continue the loop with decremented iterations
        execute_tool_loop(config, iterations_left - 1)
    end
  end

  @doc """
  Stream a response from the LLM with real-time callbacks.

  This method enables streaming mode, allowing you to process LLM responses
  as they're generated. Callbacks are invoked for each event type.

  ## Parameters
    - config: Agent configuration
    - user_input: Optional user input (can be nil to continue conversation)
    - callback: Function `(event_type, data) -> :ok` called for each event

  ## Event Types
    - `:text_delta` - Incremental text content
    - `:tool_use_start` - Tool call beginning
    - `:thinking_delta` - Extended thinking content
    - `:message_start` - Stream beginning
    - `:message_stop` - Stream complete

  ## Returns
    `{config, final_response}` - Updated config and accumulated response

  ## Example

      callback = fn
        :text_delta, text -> IO.write(text)
        :tool_use_start, tool -> IO.puts("\\nCalling tool: \#{tool["name"]}")
        _, _ -> :ok
      end

      {agent, response} = BaseAgent.stream_response(agent, input, callback)
  """
  @spec stream_response(BaseAgentConfig.t(), struct() | nil, function()) ::
          {BaseAgentConfig.t(), map()}
  def stream_response(config, user_input \\ nil, callback) when is_function(callback, 2) do
    # Add user input to memory if provided
    {config, memory} =
      if user_input != nil do
        updated_memory =
          config.memory
          |> AgentMemory.initialize_turn()
          |> AgentMemory.add_message("user", user_input)

        updated_config =
          config
          |> Map.put(:current_user_input, user_input)
          |> Map.put(:memory, updated_memory)

        {updated_config, updated_memory}
      else
        {config, config.memory}
      end

    # Build messages for LLM
    messages =
      [
        %Message{
          role: "system",
          content:
            SystemPromptGenerator.generate_prompt(
              config.prompt_specification,
              config.tool_registry
            )
        }
      ] ++ AgentMemory.history(memory)

    # Prepare options with tools and callback
    opts =
      if has_tools?(config) do
        tool_schemas = Registry.to_tool_schemas(config.tool_registry)
        [tools: tool_schemas, callback: callback]
      else
        [callback: callback]
      end

    # Stream response from LLM
    case stream_response_from_llm(config, messages, opts) do
      {:ok, final_response} ->
        # Add response to memory
        updated_memory = AgentMemory.add_message(memory, "assistant", final_response)
        updated_config = Map.put(config, :memory, updated_memory)
        {updated_config, final_response}

      {:error, error} ->
        # Handle error - return config unchanged
        IO.warn("Streaming error: #{inspect(error)}")
        {config, %{error: error}}
    end
  end

  @doc """
  Stream responses with tool calling support.

  Combines streaming and tool execution - as the LLM streams its response,
  tool calls are detected and executed, with results fed back into the stream.

  ## Parameters
    - config: Agent configuration
    - user_input: Optional user input to start the conversation
    - callback: Function `(event_type, data) -> :ok` called for each event

  ## Event Types
    - `:text_delta` - Incremental text content
    - `:tool_use_start` - Tool call beginning
    - `:tool_result` - Tool execution result (custom event)
    - `:thinking_delta` - Extended thinking content
    - `:message_start` - Stream beginning
    - `:message_stop` - Stream complete

  ## Returns
    `{config, final_response}` - Updated config and accumulated response

  ## Example

      callback = fn
        :text_delta, text -> IO.write(text)
        :tool_use_start, tool -> IO.puts("\\nCalling tool: \#{tool["name"]}")
        :tool_result, result -> IO.puts("Tool result: \#{inspect(result)}")
        _, _ -> :ok
      end

      {agent, response} = BaseAgent.stream_with_tools(agent, input, callback)

  """
  @spec stream_with_tools(BaseAgentConfig.t(), struct() | nil, function()) ::
          {BaseAgentConfig.t(), struct()}
  def stream_with_tools(
        config = %BaseAgentConfig{memory: memory, max_tool_iterations: max_iterations},
        user_input \\ nil,
        callback
      )
      when is_function(callback, 2) do
    # Initialize turn with user input if provided
    memory =
      if user_input != nil do
        memory
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", user_input)
      else
        memory
      end

    config =
      if user_input != nil do
        config
        |> Map.put(:current_user_input, user_input)
        |> Map.put(:memory, memory)
      else
        config
      end

    # Execute streaming tool loop
    execute_streaming_tool_loop(config, max_iterations, callback)
  end

  # Private function to handle the streaming tool execution loop
  defp execute_streaming_tool_loop(config, iterations_left, callback)
       when iterations_left <= 0 do
    # Max iterations reached, get final streaming response
    stream_response(config, nil, callback)
  end

  defp execute_streaming_tool_loop(config, iterations_left, callback) do
    alias Normandy.Components.ToolResult
    alias Normandy.Tools.Executor

    # Build messages for LLM
    messages =
      [
        %Message{
          role: "system",
          content:
            SystemPromptGenerator.generate_prompt(
              config.prompt_specification,
              config.tool_registry
            )
        }
      ] ++ AgentMemory.history(config.memory)

    # Prepare options with tools and callback
    opts =
      if has_tools?(config) do
        tool_schemas = Registry.to_tool_schemas(config.tool_registry)
        [tools: tool_schemas, callback: callback]
      else
        [callback: callback]
      end

    # Stream response from LLM
    case stream_response_from_llm(config, messages, opts) do
      {:ok, final_response} ->
        # Check if response contains tool calls
        tool_calls = extract_tool_calls(final_response)

        cond do
          # No tool calls - final response
          is_nil(tool_calls) or length(tool_calls) == 0 ->
            memory = AgentMemory.add_message(config.memory, "assistant", final_response)
            config = Map.put(config, :memory, memory)
            {config, final_response}

          # Has tool calls - execute them
          true ->
            # Add assistant message with tool calls to memory
            memory = AgentMemory.add_message(config.memory, "assistant", final_response)

            # Execute each tool call
            tool_results =
              Enum.map(tool_calls, fn tool_call ->
                result =
                  case Executor.execute(config.tool_registry, tool_call["name"]) do
                    {:ok, result} ->
                      %ToolResult{
                        tool_call_id: tool_call["id"],
                        output: result,
                        is_error: false
                      }

                    {:error, error} ->
                      %ToolResult{
                        tool_call_id: tool_call["id"],
                        output: %{error: error},
                        is_error: true
                      }
                  end

                # Notify callback about tool result
                callback.(:tool_result, result)
                result
              end)

            # Add tool results to memory
            memory =
              Enum.reduce(tool_results, memory, fn result, mem ->
                AgentMemory.add_message(mem, "tool", result)
              end)

            config = Map.put(config, :memory, memory)

            # Continue the loop with decremented iterations
            execute_streaming_tool_loop(config, iterations_left - 1, callback)
        end

      {:error, error} ->
        # Handle error
        IO.warn("Streaming error: #{inspect(error)}")
        {config, %{error: error}}
    end
  end

  # Extract tool calls from streaming response
  defp extract_tool_calls(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> case do
      [] -> nil
      tool_calls -> tool_calls
    end
  end

  defp extract_tool_calls(_response), do: nil

  # Private helper to stream from LLM
  defp stream_response_from_llm(config, messages, opts) do
    # Check if client protocol implements stream_converse
    impl = Normandy.Agents.Model.impl_for(config.client)

    if impl && function_exported?(impl, :stream_converse, 7) do
      case impl.stream_converse(
             config.client,
             config.model,
             config.temperature,
             config.max_tokens,
             messages,
             config.output_schema,
             opts
           ) do
        {:ok, stream} ->
          # Process the stream and build final message
          events = Enum.to_list(stream)
          final_message = Normandy.Components.StreamProcessor.build_final_message(events)
          {:ok, final_message}

        {:error, _} = error ->
          error
      end
    else
      {:error, "Client does not support streaming"}
    end
  end

  @spec get_context_provider(BaseAgentConfig.t(), atom()) :: struct()
  def get_context_provider(
        %BaseAgentConfig{prompt_specification: prompt_specification},
        provider_name
      ) do
    context_provider =
      Map.get(prompt_specification, :context_providers, nil)
      |> Map.get(provider_name, nil)

    if context_provider == nil do
      raise Normandy.NonExistentContextProvider, value: provider_name
    else
      context_provider
    end
  end

  @spec register_context_provider(BaseAgentConfig.t(), atom(), struct()) ::
          BaseAgentConfig.t()
  def register_context_provider(
        config = %BaseAgentConfig{prompt_specification: prompt_specification},
        provider_name,
        provider
      ) do
    context_providers =
      prompt_specification.context_providers
      |> Map.put(provider_name, provider)

    prompt_specification = Map.put(prompt_specification, :context_providers, context_providers)
    Map.put(config, :prompt_specification, prompt_specification)
  end

  @spec delete_context_provider(BaseAgentConfig.t(), atom()) :: BaseAgentConfig.t()
  def delete_context_provider(
        config = %BaseAgentConfig{prompt_specification: prompt_specification},
        provider_name
      ) do
    context_providers =
      prompt_specification.context_providers
      |> Map.delete(provider_name)

    prompt_specification = Map.put(prompt_specification, :context_providers, context_providers)
    Map.put(config, :prompt_specification, prompt_specification)
  end

  # Tool management functions

  @doc """
  Registers a tool in the agent's tool registry.

  Creates a new registry if one doesn't exist.

  ## Examples

      iex> agent = BaseAgent.init(config)
      iex> tool = %Normandy.Tools.Examples.Calculator{}
      iex> agent = BaseAgent.register_tool(agent, tool)

  """
  @spec register_tool(BaseAgentConfig.t(), struct()) :: BaseAgentConfig.t()
  def register_tool(%BaseAgentConfig{tool_registry: nil} = config, tool) do
    registry = Registry.new([tool])
    %{config | tool_registry: registry}
  end

  def register_tool(%BaseAgentConfig{tool_registry: registry} = config, tool) do
    updated_registry = Registry.register(registry, tool)
    %{config | tool_registry: updated_registry}
  end

  @doc """
  Gets a tool from the agent's tool registry by name.

  ## Examples

      iex> agent = BaseAgent.register_tool(agent, %Calculator{})
      iex> BaseAgent.get_tool(agent, "calculator")
      {:ok, %Calculator{}}

  """
  @spec get_tool(BaseAgentConfig.t(), String.t()) :: {:ok, struct()} | :error
  def get_tool(%BaseAgentConfig{tool_registry: nil}, _tool_name), do: :error

  def get_tool(%BaseAgentConfig{tool_registry: registry}, tool_name) do
    Registry.get(registry, tool_name)
  end

  @doc """
  Lists all tools available to the agent.

  ## Examples

      iex> BaseAgent.list_tools(agent)
      [%Calculator{}, %StringManipulator{}]

  """
  @spec list_tools(BaseAgentConfig.t()) :: [struct()]
  def list_tools(%BaseAgentConfig{tool_registry: nil}), do: []

  def list_tools(%BaseAgentConfig{tool_registry: registry}) do
    Registry.list(registry)
  end

  @doc """
  Checks if the agent has any tools registered.

  ## Examples

      iex> BaseAgent.has_tools?(agent)
      true

  """
  @spec has_tools?(BaseAgentConfig.t()) :: boolean()
  def has_tools?(%BaseAgentConfig{tool_registry: nil}), do: false
  def has_tools?(%BaseAgentConfig{tool_registry: registry}), do: Registry.count(registry) > 0
end
