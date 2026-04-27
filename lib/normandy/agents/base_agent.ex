defmodule Normandy.Agents.BaseAgent do
  @moduledoc """
  Core agent implementation providing conversational AI capabilities.

  BaseAgent manages agent state, memory, and LLM interactions through a
  stateful configuration approach.
  """

  require Logger

  alias Normandy.Components.SystemPromptGenerator
  alias Normandy.Components.Message
  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ToolResult
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.BaseAgentOutputSchema

  alias Normandy.Tools.Executor
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
          optional(:max_tool_iterations) => pos_integer(),
          optional(:max_tool_concurrency) => pos_integer(),
          optional(:retry_options) => keyword(),
          optional(:enable_circuit_breaker) => boolean(),
          optional(:circuit_breaker_options) => keyword(),
          optional(:enable_json_retry) => boolean(),
          optional(:json_retry_max_attempts) => pos_integer(),
          optional(:input_guardrails) => [Normandy.Guardrails.spec()],
          optional(:output_guardrails) => [Normandy.Guardrails.spec()],
          optional(:output_guardrails_streaming_mode) => :accumulate | :incremental,
          optional(:output_guardrails_chunk_size) => pos_integer()
        }

  @spec init(config_input()) :: BaseAgentConfig.t()
  def init(config) do
    # Validate guardrail config BEFORE starting the circuit breaker process;
    # otherwise a bad config would leak a linked breaker before we raise.
    input_guardrails = Map.get(config, :input_guardrails, [])
    output_guardrails = Map.get(config, :output_guardrails, [])

    unless is_list(input_guardrails) do
      raise ArgumentError,
            "input_guardrails must be a list of guard specs, got: #{inspect(input_guardrails)}"
    end

    unless is_list(output_guardrails) do
      raise ArgumentError,
            "output_guardrails must be a list of guard specs, got: #{inspect(output_guardrails)}"
    end

    streaming_mode = Map.get(config, :output_guardrails_streaming_mode, :accumulate)
    chunk_size = Map.get(config, :output_guardrails_chunk_size, 200)

    unless streaming_mode in [:accumulate, :incremental] do
      raise ArgumentError,
            "output_guardrails_streaming_mode must be :accumulate or :incremental, got: #{inspect(streaming_mode)}"
    end

    unless is_integer(chunk_size) and chunk_size > 0 do
      raise ArgumentError,
            "output_guardrails_chunk_size must be a positive integer, got: #{inspect(chunk_size)}"
    end

    # Initialize circuit breaker if enabled
    circuit_breaker =
      if Map.get(config, :enable_circuit_breaker, false) do
        cb_opts = Map.get(config, :circuit_breaker_options, [])
        {:ok, cb} = Normandy.Resilience.CircuitBreaker.start_link(cb_opts)
        cb
      else
        nil
      end

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
      max_tool_iterations: Map.get(config, :max_tool_iterations, 5),
      max_tool_concurrency:
        normalize_max_tool_concurrency(Map.get(config, :max_tool_concurrency, 1)),
      retry_options: Map.get(config, :retry_options, nil),
      circuit_breaker: circuit_breaker,
      enable_json_retry: Map.get(config, :enable_json_retry, false),
      json_retry_max_attempts: Map.get(config, :json_retry_max_attempts, 2),
      mcp_servers: Map.get(config, :mcp_servers, nil),
      name: Map.get(config, :name, nil),
      input_guardrails: input_guardrails,
      output_guardrails: output_guardrails,
      output_guardrails_streaming_mode: streaming_mode,
      output_guardrails_chunk_size: chunk_size
    }
  end

  @spec reset_memory(BaseAgentConfig.t()) :: BaseAgentConfig.t()
  def reset_memory(config = %BaseAgentConfig{initial_memory: memory}) do
    Map.put(config, :memory, memory)
  end

  @spec get_response(BaseAgentConfig.t(), struct() | nil) :: struct()
  def get_response(config = %BaseAgentConfig{}, response_model \\ nil) do
    {response, _usage} = get_response_with_usage(config, response_model)
    response
  end

  # Coerce inbound `:max_tool_concurrency` into the `pos_integer()` shape the
  # struct's typespec promises. Integers < 1 are clamped to 1 (matches the
  # runtime tool-loop clamp). Non-integers raise — silently coercing `"4"` or
  # `4.0` to 1 hides a real config bug from the caller. Public so the DSL
  # `__before_compile__` quote can reuse it for compile-time validation.
  @doc false
  def normalize_max_tool_concurrency(n) when is_integer(n) and n >= 1, do: n
  def normalize_max_tool_concurrency(n) when is_integer(n) and n < 1, do: 1

  def normalize_max_tool_concurrency(other) do
    raise ArgumentError,
          ":max_tool_concurrency must be an integer >= 1, got: #{inspect(other)}"
  end

  @spec get_response_with_usage(BaseAgentConfig.t(), struct() | nil) :: {struct(), map() | nil}
  defp get_response_with_usage(
         config = %BaseAgentConfig{prompt_specification: prompt_specification},
         response_model
       ) do
    response_model =
      if response_model != nil do
        response_model
      else
        Map.get(config, :output_schema)
      end

    history = AgentMemory.history(config.memory)

    # Generate system prompt and add output schema specification
    system_prompt =
      SystemPromptGenerator.generate_prompt(prompt_specification, config.tool_registry)

    # Add output schema if available
    system_prompt_with_schema =
      if response_model do
        try do
          schema_json =
            Poison.encode!(response_model.__struct__.__specification__(), pretty: true)

          system_prompt <>
            "\n\n# OUTPUT SCHEMA\nYou MUST respond with valid JSON that exactly matches this schema. Use these exact field names:\n```json\n#{schema_json}\n```\nIMPORTANT: The response must be valid JSON with the field names shown above. Do not add extra fields or change field names."
        rescue
          _ ->
            system_prompt
        end
      else
        system_prompt
      end

    # Convert history plain maps to Message structs
    history_messages =
      Enum.map(history, fn %{role: role, content: content} ->
        %Message{role: role, content: content}
      end)

    messages =
      [
        %Message{
          role: "system",
          content: system_prompt_with_schema
        }
      ] ++ history_messages

    # Prepare tool schemas if tools are available
    opts =
      if has_tools?(config) do
        tool_schemas = Registry.to_tool_schemas(config.tool_registry)
        [tools: tool_schemas]
      else
        []
      end

    # Pass MCP server configs through to the LLM adapter
    opts =
      if config.mcp_servers do
        Keyword.put(opts, :mcp_servers, config.mcp_servers)
      else
        opts
      end

    # Wrap LLM call with resilience patterns
    call_llm_with_resilience(config, messages, response_model, opts)
  end

  # Private helper to call LLM with retry and circuit breaker protection
  @spec call_llm_with_resilience(BaseAgentConfig.t(), list(), struct(), keyword()) ::
          {struct(), map() | nil}
  defp call_llm_with_resilience(config, messages, response_model, opts) do
    llm_call = fn ->
      result =
        Normandy.Agents.Model.converse(
          config.client,
          config.model,
          config.temperature,
          config.max_tokens,
          messages,
          response_model,
          opts
        )

      # Wrap in {:ok, result} for retry/circuit breaker compatibility
      {:ok, result}
    end

    # Apply retry first if configured, then circuit breaker wraps the whole thing
    retryable_call =
      if config.retry_options do
        fn ->
          # Add default retry_if for exceptions if not provided
          retry_opts =
            if !Keyword.has_key?(config.retry_options, :retry_if) do
              Keyword.put(config.retry_options, :retry_if, fn
                {:error, {:exception, _, _}} -> true
                {:error, :open} -> false
                {:error, error} when is_atom(error) -> true
                _ -> false
              end)
            else
              config.retry_options
            end

          Normandy.Resilience.Retry.with_retry(llm_call, retry_opts)
        end
      else
        llm_call
      end

    # Apply circuit breaker if configured (wraps the retry logic)
    protected_call =
      if config.circuit_breaker do
        fn ->
          Normandy.Resilience.CircuitBreaker.call(config.circuit_breaker, retryable_call)
        end
      else
        retryable_call
      end

    # Execute and unwrap result
    result =
      case protected_call.() do
        {:ok, {:ok, response}} -> normalize_model_response(response)
        {:ok, response} -> normalize_model_response(response)
        {:error, {reason, _attempts, _errors}} -> raise_llm_call_error(reason)
        {:error, reason} -> raise_llm_call_error(reason)
      end

    result
  end

  @spec run(BaseAgentConfig.t(), struct() | map() | nil) :: {BaseAgentConfig.t(), struct()}
  def run(
        config = %BaseAgentConfig{tool_registry: tool_registry},
        user_input \\ nil
      ) do
    metadata = %{model: config.model, agent_name: config.name}

    with_agent_run_span(config, metadata, fn ->
      result =
        if tool_registry != nil && Registry.count(tool_registry) > 0 do
          run_with_tools(config, user_input)
        else
          # No tools registered, use simple response
          run_without_tools(config, user_input)
        end

      {result, metadata}
    end)
  end

  @doc """
  Run the agent with optional streaming support.

  Accepts a keyword list as the third argument with options:
  - `:stream` - Boolean, enables streaming mode
  - `:on_chunk` - Callback function for streaming chunks

  ## Example

      BaseAgent.run(agent, %{chat_message: "Hello"}, stream: true, on_chunk: fn chunk ->
        IO.write(chunk)
      end)
  """
  def run(config, user_input, opts) when is_list(opts) do
    stream = Keyword.get(opts, :stream, false)
    on_chunk = Keyword.get(opts, :on_chunk)

    if stream and on_chunk do
      metadata = %{model: config.model, agent_name: config.name}

      # Convert arity-1 callback to arity-2 if needed
      callback =
        if is_function(on_chunk, 1) do
          fn
            :text_delta, text -> on_chunk.(text)
            _, _ -> :ok
          end
        else
          on_chunk
        end

      with_agent_run_span(config, metadata, fn ->
        # Mirror run/2's dispatch: if the agent has tools, drive the
        # streaming tool loop so tool_use blocks actually execute. Without
        # this, agents with tools stream back a tool_use event, the tool
        # never runs, and the user sees an empty assistant message.
        result =
          if has_tools?(config) do
            stream_with_tools(config, user_input, callback)
          else
            stream_response(config, user_input, callback)
          end

        {result, metadata}
      end)
    else
      # Fall back to regular run
      run(config, user_input)
    end
  end

  # Private function for simple runs without tool support
  defp run_without_tools(
         config = %BaseAgentConfig{memory: memory, output_schema: output_schema},
         user_input
       ) do
    alias Normandy.Agents.ValidationMiddleware

    # Validate input if provided
    config =
      if user_input != nil do
        # Validate user input against input schema
        case ValidationMiddleware.validate_input(config, user_input) do
          {:ok, validated_input} ->
            effective_input = validated_input || user_input
            run_input_guardrails!(config, effective_input)

            updated_memory =
              memory
              |> AgentMemory.initialize_turn()
              |> AgentMemory.add_message("user", effective_input)

            config
            |> Map.put(:current_user_input, effective_input)
            |> Map.put(:memory, updated_memory)

          {:error, errors} ->
            # Input validation failed - raise error with details
            error_msg = ValidationMiddleware.error_message(errors)

            raise Normandy.Schema.ValidationError,
              message: "Agent input validation failed",
              errors: errors,
              details: error_msg
        end
      else
        config
      end

    # Get response from LLM
    llm_metadata = %{model: config.model, iteration: 1, agent_name: config.name}

    response =
      with_llm_call_span(config, llm_metadata, fn ->
        {r, usage} = get_response_with_usage(config, output_schema)

        {r, Map.merge(llm_metadata, %{has_tool_calls: false, tool_call_count: 0, usage: usage})}
      end)

    # Validate output
    validated_response =
      case ValidationMiddleware.validate_output(config, response) do
        {:ok, validated} ->
          validated || response

        {:error, errors} ->
          # Output validation failed - log warning but continue
          # (we don't want to break on LLM output issues)
          error_msg = ValidationMiddleware.error_message(errors)

          IO.warn("Agent output validation failed: #{error_msg}\nReceived: #{inspect(response)}")

          response
      end

    run_output_guardrails(config, validated_response)

    memory = AgentMemory.add_message(config.memory, "assistant", validated_response)
    config = Map.put(config, :memory, memory)

    {config, validated_response}
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
    alias Normandy.Agents.ValidationMiddleware

    # Validate and initialize turn with user input if provided
    {config, _memory} =
      if user_input != nil do
        # Validate user input
        validated_input =
          case ValidationMiddleware.validate_input(config, user_input) do
            {:ok, validated} ->
              validated || user_input

            {:error, errors} ->
              error_msg = ValidationMiddleware.error_message(errors)

              raise Normandy.Schema.ValidationError,
                message: "Agent input validation failed",
                errors: errors,
                details: error_msg
          end

        run_input_guardrails!(config, validated_input)

        updated_memory =
          memory
          |> AgentMemory.initialize_turn()
          |> AgentMemory.add_message("user", validated_input)

        updated_config =
          config
          |> Map.put(:current_user_input, validated_input)
          |> Map.put(:memory, updated_memory)

        {updated_config, updated_memory}
      else
        {config, memory}
      end

    # Execute tool loop
    execute_tool_loop(config, max_iterations)
  end

  # Private function to handle the tool execution loop
  defp execute_tool_loop(config, iterations_left) when iterations_left <= 0 do
    alias Normandy.Agents.ValidationMiddleware

    # Max iterations reached, return current state. Validate the fallback
    # output the same way the normal final-response path does so that output
    # guardrails observe a consistent, schema-cast shape on both branches.
    response = get_response(config, config.output_schema)

    validated_response =
      case ValidationMiddleware.validate_output(config, response) do
        {:ok, validated} ->
          validated || response

        {:error, errors} ->
          error_msg = ValidationMiddleware.error_message(errors)
          IO.warn("Agent output validation failed: #{error_msg}\nReceived: #{inspect(response)}")
          response
      end

    run_output_guardrails(config, validated_response)
    memory = AgentMemory.add_message(config.memory, "assistant", validated_response)
    config = Map.put(config, :memory, memory)
    {config, validated_response}
  end

  defp execute_tool_loop(config, iterations_left) do
    alias Normandy.Agents.ToolCallResponse

    # Get response from LLM (may include tool calls)
    iteration = config.max_tool_iterations - iterations_left + 1
    llm_metadata = %{model: config.model, iteration: iteration, agent_name: config.name}

    log_lifecycle(:debug, "normandy agent iteration",
      agent: log_agent_name(config),
      iteration: iteration,
      pending_tool_calls: pending_tool_call_count(config)
    )

    response =
      with_llm_call_span(config, llm_metadata, fn ->
        {r, usage} = get_response_with_usage(config, %ToolCallResponse{})
        tool_calls = r.tool_calls || []
        has_tools = tool_calls != []

        {r,
         Map.merge(llm_metadata, %{
           has_tool_calls: has_tools,
           tool_call_count: length(tool_calls),
           usage: usage
         })}
      end)

    cond do
      # No tool calls - this IS the final text response, just in ToolCallResponse format
      # We need to convert it to the actual output schema
      is_nil(response.tool_calls) or length(response.tool_calls) == 0 ->
        alias Normandy.Agents.ValidationMiddleware

        # Convert ToolCallResponse to actual output schema
        # The response.content contains the final text
        final_response =
          if response.content && response.content != "" do
            # We have content in the ToolCallResponse, convert to output schema
            case config.output_schema do
              %{chat_message: _} ->
                text = unwrap_llm_content(response.content)
                Map.put(config.output_schema, :chat_message, text)

              _ ->
                config.output_schema
            end
          else
            config.output_schema
          end

        # Validate output
        validated_response =
          case ValidationMiddleware.validate_output(config, final_response) do
            {:ok, validated} ->
              validated || final_response

            {:error, errors} ->
              # Output validation failed - log warning but continue
              error_msg = ValidationMiddleware.error_message(errors)

              IO.warn(
                "Agent output validation failed: #{error_msg}\nReceived: #{inspect(final_response)}"
              )

              final_response
          end

        run_output_guardrails(config, validated_response)

        memory = AgentMemory.add_message(config.memory, "assistant", validated_response)
        config = Map.put(config, :memory, memory)
        {config, validated_response}

      # Has tool calls - execute them
      true ->
        # Add assistant message with tool calls to memory
        memory = AgentMemory.add_message(config.memory, "assistant", response)

        # Tool calls run through `Task.async_stream` so an agent can opt into
        # bounded parallel execution via `max_tool_concurrency` (default `1` =
        # sequential). `ordered: true` keeps tool_results in the LLM's call
        # order, which downstream code (and Anthropic's tool_result pairing)
        # may rely on. The per-tool 30 s timeout already lives in
        # `Executor.execute_tool/2`, so the outer stream stays `:infinity`.
        # `parent_otel_ctx` is captured once and re-attached in each worker so
        # tool spans nest under the parent agent.run span (the worker process
        # has a fresh process dict).
        parent_otel_ctx = capture_otel_ctx()
        max_concurrency = max(config.max_tool_concurrency || 1, 1)

        tool_results =
          response.tool_calls
          |> Task.async_stream(
            fn tool_call ->
              restore_otel_ctx(parent_otel_ctx)
              execute_one_tool_call(config, tool_call)
            end,
            ordered: true,
            max_concurrency: max_concurrency,
            timeout: :infinity,
            on_timeout: :kill_task
          )
          |> Enum.map(fn {:ok, result} -> result end)

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

  @doc false
  def unwrap_llm_content(content) when is_binary(content) do
    case Poison.decode(content) do
      {:ok, %{"chat_message" => text}} when is_binary(text) -> text
      _ -> content
    end
  end

  @doc false
  def unwrap_llm_content(content), do: content

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
    # Streaming paths do not schema-validate input (unlike run_without_tools/run_with_tools),
    # so guardrails run on the raw user_input shape here. Guards using `:field` must name
    # keys present on the raw input — or use a field-less guard that inspects the whole value.
    if user_input != nil, do: run_input_guardrails!(config, user_input)

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

    # Convert history plain maps to Message structs so the LLM adapter's
    # pattern-matched add_single_message picks them up. Without this, the
    # adapter's catch-all silently drops every history entry — streaming
    # requests reach the API with only the system message, and the API
    # rejects them as empty (`messages: at least one message is required`).
    history_messages =
      AgentMemory.history(memory)
      |> Enum.map(fn %{role: role, content: content} ->
        %Message{role: role, content: content}
      end)

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
      ] ++ history_messages

    # Prepare options with tools and callback
    opts =
      if has_tools?(config) do
        tool_schemas = Registry.to_tool_schemas(config.tool_registry)
        [tools: tool_schemas, callback: callback]
      else
        [callback: callback]
      end

    llm_metadata = %{model: config.model, iteration: 1, agent_name: config.name}

    # Stream response from LLM
    llm_result =
      with_llm_call_span(config, llm_metadata, fn ->
        result = stream_response_from_llm(config, messages, opts)

        stop_metadata =
          case result do
            {:ok, final_response} ->
              tool_calls = extract_tool_calls(final_response) || []

              Map.merge(llm_metadata, %{
                has_tool_calls: tool_calls != [],
                tool_call_count: length(tool_calls)
              })

            {:error, _error} ->
              Map.merge(llm_metadata, %{has_tool_calls: false, tool_call_count: 0})
          end

        {result, stop_metadata}
      end)

    case llm_result do
      {:ok, final_response} ->
        final_response = run_streaming_output_guardrails(config, final_response, callback)
        # Strip guardrail metadata before persisting — otherwise the violating
        # turn (plus matched terms from violations) feeds back into the next
        # LLM call via AgentMemory.history/1.
        memory_response = Map.delete(final_response, :guardrail_violations)
        updated_memory = AgentMemory.add_message(memory, "assistant", memory_response)
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
    - `:guardrail_violation` - Output guardrail violation

  ## Returns
    `{config, final_response}` - Updated config and accumulated response

  ## Guardrail Semantics

  If `:output_guardrails_streaming_mode` is `:incremental` and a violation
  fires mid-stream, the current iteration is halted and any in-flight
  `tool_use` content block is stripped from the returned response — the
  caller won't execute a tool whose arguments were still streaming. Tool
  results from *earlier* iterations remain in memory; memory commits
  happen after each stream ends, not after the loop completes.

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
    # See stream_response/3: streaming paths run guardrails on raw user_input.
    if user_input != nil, do: run_input_guardrails!(config, user_input)

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
    iteration = config.max_tool_iterations - iterations_left + 1
    llm_metadata = %{model: config.model, iteration: iteration, agent_name: config.name}

    log_lifecycle(:debug, "normandy agent iteration",
      agent: log_agent_name(config),
      iteration: iteration,
      pending_tool_calls: pending_tool_call_count(config)
    )

    # Convert history plain maps to Message structs (see stream_response for why).
    history_messages =
      AgentMemory.history(config.memory)
      |> Enum.map(fn %{role: role, content: content} ->
        %Message{role: role, content: content}
      end)

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
      ] ++ history_messages

    # Prepare options with tools and callback
    opts =
      if has_tools?(config) do
        tool_schemas = Registry.to_tool_schemas(config.tool_registry)
        [tools: tool_schemas, callback: callback]
      else
        [callback: callback]
      end

    # Stream response from LLM
    llm_result =
      with_llm_call_span(config, llm_metadata, fn ->
        result = stream_response_from_llm(config, messages, opts)

        stop_metadata =
          case result do
            {:ok, final_response} ->
              tool_calls = extract_tool_calls(final_response) || []

              Map.merge(llm_metadata, %{
                has_tool_calls: tool_calls != [],
                tool_call_count: length(tool_calls)
              })

            {:error, _error} ->
              Map.merge(llm_metadata, %{has_tool_calls: false, tool_call_count: 0})
          end

        {result, stop_metadata}
      end)

    case llm_result do
      {:ok, final_response} ->
        # Check if response contains tool calls
        tool_calls = extract_tool_calls(final_response)

        cond do
          # No tool calls - final response
          is_nil(tool_calls) or length(tool_calls) == 0 ->
            # Run output guardrails on the final text response. Intermediate
            # tool-call responses are not user-facing output and are skipped.
            final_response = run_streaming_output_guardrails(config, final_response, callback)
            # Store as ToolCallResponse so BaseIOSchema serialization emits
            # content blocks (Map.to_json would JSON-stringify the whole map).
            assistant_response = build_streaming_assistant_response(final_response, [])
            memory = AgentMemory.add_message(config.memory, "assistant", assistant_response)
            config = Map.put(config, :memory, memory)
            {config, final_response}

          # Has tool calls - execute them
          true ->
            # Store assistant response as ToolCallResponse so the next
            # iteration's history preserves tool_use blocks (Anthropic
            # requires each tool_result to pair with the prior tool_use).
            assistant_response = build_streaming_assistant_response(final_response, tool_calls)
            memory = AgentMemory.add_message(config.memory, "assistant", assistant_response)

            # Same Task.async_stream parallelism as the non-streaming branch
            # (see comment there). Streaming additionally invokes
            # `callback.(:tool_result, result)` per tool — at concurrency 1
            # the callback fires in input order; at concurrency > 1 callbacks
            # fire in tool-completion order, and the closure runs in a worker
            # process so any `self()` reference inside the callback is the
            # worker PID, not the caller. Capture parent PID outside the
            # callback when sending messages to the owning process.
            parent_otel_ctx = capture_otel_ctx()
            max_concurrency = max(config.max_tool_concurrency || 1, 1)

            tool_results =
              tool_calls
              |> Task.async_stream(
                fn tool_call ->
                  restore_otel_ctx(parent_otel_ctx)
                  result = execute_one_streaming_tool_call(config, tool_call)
                  callback.(:tool_result, result)
                  result
                end,
                ordered: true,
                max_concurrency: max_concurrency,
                timeout: :infinity,
                on_timeout: :kill_task
              )
              |> Enum.map(fn {:ok, result} -> result end)

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

  # Build a ToolCallResponse from a streamed final_response so the assistant
  # turn survives AgentMemory.history/1 re-serialization. Without this, the
  # generic Map BaseIOSchema impl stringifies the whole response map and the
  # next LLM call loses its tool_use content blocks.
  defp build_streaming_assistant_response(%{content: content}, tool_calls)
       when is_list(content) do
    alias Normandy.Agents.ToolCallResponse
    alias Normandy.Components.ToolCall

    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(&Map.get(&1, "text", ""))
      |> Enum.join("")

    calls =
      Enum.map(tool_calls || [], fn block ->
        %ToolCall{
          id: block["id"],
          name: block["name"],
          input: normalize_tool_input(block["input"])
        }
      end)

    %ToolCallResponse{
      content: if(text == "", do: nil, else: text),
      tool_calls: calls
    }
  end

  defp build_streaming_assistant_response(other, _), do: other

  defp normalize_tool_input(nil), do: %{}
  defp normalize_tool_input(input) when is_map(input), do: input

  defp normalize_tool_input(input) when is_binary(input) do
    case Poison.decode(input) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{}
    end
  end

  defp normalize_tool_input(_), do: %{}

  # Map an LLM-supplied input key (atom or binary) to a struct field atom on
  # the tool, returning :error for keys that don't correspond to any field.
  #
  # Crucially, this NEVER calls String.to_atom/1 on untrusted input. Tool
  # input keys come from LLM JSON, which is influenced by attacker-
  # controllable prompt content; String.to_atom/1 would register every
  # unknown key in the global atom table (the BEAM never garbage-collects
  # atoms), so a sustained stream of crafted random keys would eventually
  # exhaust the atom table and crash the VM. struct/2 silently dropping the
  # field at the next step doesn't undo the atom allocation that already
  # happened.
  #
  # Returns {:ok, atom} for known fields, :error otherwise. Callers should
  # silently drop :error results to preserve struct/2's effective behaviour
  # of ignoring unknown keys.
  defp normalize_tool_field_key(tool, key) when is_atom(key) do
    if key != :__struct__ and Map.has_key?(tool, key), do: {:ok, key}, else: :error
  end

  defp normalize_tool_field_key(tool, key) when is_binary(key) do
    Enum.find_value(Map.keys(tool), :error, fn field ->
      if is_atom(field) and field != :__struct__ and Atom.to_string(field) == key do
        {:ok, field}
      end
    end)
  end

  defp normalize_tool_field_key(_tool, _key), do: :error

  # Soft OpenTelemetry context propagation. Normandy doesn't depend on
  # :opentelemetry directly — consumers wire it up via telemetry handlers.
  # When OTel is loaded, capture the active context in the parent process so
  # the Task.async_stream worker can re-attach it; spans created inside the
  # worker (by `:telemetry.span` handlers downstream) then nest under the
  # parent agent.run span instead of becoming root spans in their own trace.
  # When OTel is not loaded, both helpers are cheap no-ops.
  defp capture_otel_ctx do
    if Code.ensure_loaded?(OpenTelemetry.Ctx) and
         function_exported?(OpenTelemetry.Ctx, :get_current, 0) do
      apply(OpenTelemetry.Ctx, :get_current, [])
    end
  end

  defp restore_otel_ctx(nil), do: :ok

  defp restore_otel_ctx(ctx) do
    if function_exported?(OpenTelemetry.Ctx, :attach, 1) do
      apply(OpenTelemetry.Ctx, :attach, [ctx])
    end

    :ok
  end

  # Private helper to stream from LLM
  defp stream_response_from_llm(config, messages, opts) do
    # Check if client protocol implements stream_converse
    impl = Normandy.Agents.Model.impl_for(config.client)

    # `function_exported?/3` returns false until the module is loaded. With
    # protocol consolidation (prod/dev), the impl module is not auto-loaded,
    # so a cold-start stream call would fail with "Client does not support
    # streaming" even when the adapter does implement stream_converse/7.
    # Ensure the module is loaded before probing.
    if impl, do: Code.ensure_loaded(impl)

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
          case config do
            %BaseAgentConfig{
              output_guardrails: [_ | _],
              output_guardrails_streaming_mode: :incremental
            } ->
              consume_stream_with_incremental_guards(
                stream,
                config,
                Keyword.get(opts, :callback)
              )

            _ ->
              events = Enum.to_list(stream)
              final_message = Normandy.Components.StreamProcessor.build_final_message(events)
              {:ok, final_message}
          end

        {:error, _} = error ->
          error
      end
    else
      {:error, "Client does not support streaming"}
    end
  end

  # Consumes a stream event-by-event, running output guards every
  # `output_guardrails_chunk_size` bytes of accumulated text. On violation,
  # halts consumption, emits telemetry + the :guardrail_violation callback
  # event, strips any partial tool-use block from the response, and returns
  # `{:ok, final_message_with_violations}`.
  defp consume_stream_with_incremental_guards(stream, config, callback) do
    guards = config.output_guardrails
    chunk_size = config.output_guardrails_chunk_size

    initial = %{events: [], accumulated: "", since_last_check: 0, violations: []}

    final_acc =
      Enum.reduce_while(stream, initial, fn event, acc ->
        text_delta = extract_text_delta_for_guard(event)
        new_accumulated = acc.accumulated <> text_delta
        new_since = acc.since_last_check + byte_size(text_delta)

        base_acc = %{
          acc
          | events: [event | acc.events],
            accumulated: new_accumulated,
            since_last_check: new_since
        }

        if text_delta != "" and new_since >= chunk_size do
          case Normandy.Guardrails.run(guards, new_accumulated) do
            {:ok, _} ->
              {:cont, %{base_acc | since_last_check: 0}}

            {:error, violations} ->
              report_incremental_violation(config, guards, violations, callback)
              {:halt, %{base_acc | violations: violations}}
          end
        else
          {:cont, base_acc}
        end
      end)

    # Tail check: when the stream ends without crossing `chunk_size` since the
    # last successful check, the tail bytes were never inspected. Run one
    # final pass so short outputs (total length < chunk_size) can't bypass
    # guards.
    final_acc =
      if final_acc.violations == [] and final_acc.since_last_check > 0 do
        case Normandy.Guardrails.run(guards, final_acc.accumulated) do
          {:ok, _} ->
            final_acc

          {:error, violations} ->
            report_incremental_violation(config, guards, violations, callback)
            %{final_acc | violations: violations}
        end
      else
        final_acc
      end

    events = Enum.reverse(final_acc.events)
    final_message = Normandy.Components.StreamProcessor.build_final_message(events)

    final_message =
      case final_acc.violations do
        [] ->
          Map.put(final_message, :guardrail_violations, [])

        violations ->
          final_message
          |> strip_partial_tool_use()
          |> Map.put(:guardrail_violations, violations)
      end

    {:ok, final_message}
  end

  defp report_incremental_violation(config, guards, violations, callback) do
    emit_guardrail_violation(:output, config, guards, violations, %{
      streaming: true,
      mode: :incremental
    })

    if is_function(callback, 2) do
      callback.(:guardrail_violation, %{
        stage: :output,
        mode: :incremental,
        violations: violations
      })
    end

    :ok
  end

  defp extract_text_delta_for_guard(%{
         type: "content_block_delta",
         delta: %{"type" => "text_delta", "text" => text}
       })
       when is_binary(text),
       do: text

  defp extract_text_delta_for_guard(_), do: ""

  # Drops non-text content blocks from the final_message. Used on incremental
  # cancel so a halted stream doesn't commit an in-flight tool-use block —
  # if we halt output, we also shouldn't execute the tool the LLM was
  # assembling.
  defp strip_partial_tool_use(%{content: content} = message) when is_list(content) do
    text_only =
      Enum.filter(content, fn
        %{"type" => "text"} -> true
        _ -> false
      end)

    %{message | content: text_only}
  end

  defp strip_partial_tool_use(message), do: message

  defp with_agent_run_span(config, telemetry_metadata, fun) do
    :telemetry.span([:normandy, :agent, :run], telemetry_metadata, fn ->
      log_lifecycle(:info, "normandy agent run start",
        agent: log_agent_name(config),
        iteration: 0,
        max_iterations: max_run_iterations(config)
      )

      started_at = System.monotonic_time()

      try do
        {result, stop_metadata} = fun.()
        duration_ms = Map.get(stop_metadata, :duration_ms, elapsed_ms(started_at))

        log_lifecycle(:info, "normandy agent run stop",
          agent: log_agent_name(config),
          iterations: completed_iterations(result),
          status: :ok,
          duration_ms: duration_ms
        )

        {result, stop_metadata}
      rescue
        error ->
          log_span_exception("normandy agent exception", config, :error, error)
          reraise(error, __STACKTRACE__)
      catch
        kind, reason ->
          log_span_exception("normandy agent exception", config, kind, reason)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end)
  end

  defp with_llm_call_span(config, telemetry_metadata, fun) do
    :telemetry.span([:normandy, :agent, :llm_call], telemetry_metadata, fn ->
      log_lifecycle(:info, "normandy llm call start",
        agent: log_agent_name(config),
        model: config.model,
        iteration: telemetry_metadata.iteration
      )

      started_at = System.monotonic_time()

      try do
        {result, stop_metadata} = fun.()
        duration_ms = elapsed_ms(started_at)
        {input_tokens, output_tokens} = token_counts(Map.get(stop_metadata, :usage) || result)

        log_lifecycle(:info, "normandy llm call stop",
          agent: log_agent_name(config),
          model: config.model,
          iteration: telemetry_metadata.iteration,
          duration_ms: duration_ms,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          has_tool_calls: Map.get(stop_metadata, :has_tool_calls, false)
        )

        {result, stop_metadata}
      rescue
        error ->
          log_span_exception("normandy llm call exception", config, :error, error,
            model: config.model,
            iteration: telemetry_metadata.iteration
          )

          reraise(error, __STACKTRACE__)
      catch
        kind, reason ->
          log_span_exception("normandy llm call exception", config, kind, reason,
            model: config.model,
            iteration: telemetry_metadata.iteration
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end)
  end

  defp with_tool_execute_span(config, tool_name, telemetry_metadata, fun) do
    :telemetry.span([:normandy, :tool, :execute], telemetry_metadata, fn ->
      log_lifecycle(:info, "normandy tool execute start",
        agent: log_agent_name(config),
        tool: tool_name
      )

      started_at = System.monotonic_time()

      try do
        {result, stop_metadata} = fun.()

        log_lifecycle(:info, "normandy tool execute stop",
          agent: log_agent_name(config),
          tool: tool_name,
          duration_ms: elapsed_ms(started_at),
          status: Map.get(stop_metadata, :status, :ok)
        )

        {result, stop_metadata}
      rescue
        error ->
          log_span_exception("normandy tool exception", config, :error, error, tool: tool_name)
          reraise(error, __STACKTRACE__)
      catch
        kind, reason ->
          log_span_exception("normandy tool exception", config, kind, reason, tool: tool_name)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end)
  end

  # Closure body extracted from the non-streaming tool loop. Resolves the tool
  # from the registry, applies the LLM-supplied input, runs it under the
  # OTel/telemetry span, and returns a `%ToolResult{}`. Pure function — safe
  # to call from inside a Task.async_stream worker.
  defp execute_one_tool_call(config, tool_call) do
    case Registry.get(config.tool_registry, tool_call.name) do
      {:ok, tool} ->
        updated_tool =
          if function_exported?(tool.__struct__, :prepare_input, 2) do
            tool.__struct__.prepare_input(tool, tool_call.input)
          else
            input_with_atom_keys =
              Enum.reduce(tool_call.input, %{}, fn {key, value}, acc ->
                case normalize_tool_field_key(tool, key) do
                  {:ok, atom_key} -> Map.put(acc, atom_key, value)
                  :error -> acc
                end
              end)

            struct(tool, input_with_atom_keys)
          end

        tool_meta = %{tool_name: tool_call.name, agent_name: config.name}

        tool_result =
          with_tool_execute_span(config, tool_call.name, tool_meta, fn ->
            r = Executor.execute_tool(updated_tool)
            {r, Map.put(tool_meta, :status, elem(r, 0))}
          end)

        case tool_result do
          {:ok, result} ->
            %ToolResult{tool_call_id: tool_call.id, output: result, is_error: false}

          {:error, error} ->
            %ToolResult{tool_call_id: tool_call.id, output: %{error: error}, is_error: true}
        end

      :error ->
        %ToolResult{
          tool_call_id: tool_call.id,
          output: %{error: "Tool '#{tool_call.name}' not found in registry"},
          is_error: true
        }
    end
  end

  # Streaming-loop variant: tool_call is a string-keyed map (from raw LLM JSON
  # rather than a parsed %ToolCall{}), and input may need JSON-string parsing.
  defp execute_one_streaming_tool_call(config, tool_call) do
    tool_name = tool_call["name"]

    # Tool input from the streaming branch is raw LLM JSON, so it can be any
    # JSON shape — not just nil/map/binary. Route through normalize_tool_input/1
    # so unexpected shapes (lists, numbers, booleans) degrade to %{} instead of
    # raising CaseClauseError and aborting the whole streaming tool loop.
    tool_input = normalize_tool_input(tool_call["input"])

    case Registry.get(config.tool_registry, tool_name) do
      {:ok, tool} ->
        updated_tool =
          if function_exported?(tool.__struct__, :prepare_input, 2) do
            tool.__struct__.prepare_input(tool, tool_input)
          else
            input_with_atom_keys =
              Enum.reduce(tool_input, %{}, fn {key, value}, acc ->
                case normalize_tool_field_key(tool, key) do
                  {:ok, atom_key} -> Map.put(acc, atom_key, value)
                  :error -> acc
                end
              end)

            struct(tool, input_with_atom_keys)
          end

        tool_meta = %{tool_name: tool_name, agent_name: config.name}

        tool_result =
          with_tool_execute_span(config, tool_name, tool_meta, fn ->
            r = Executor.execute_tool(updated_tool)
            {r, Map.put(tool_meta, :status, elem(r, 0))}
          end)

        case tool_result do
          {:ok, result} ->
            %ToolResult{tool_call_id: tool_call["id"], output: result, is_error: false}

          {:error, error} ->
            %ToolResult{tool_call_id: tool_call["id"], output: %{error: error}, is_error: true}
        end

      :error ->
        %ToolResult{
          tool_call_id: tool_call["id"],
          output: %{error: "Tool '#{tool_name}' not found in registry"},
          is_error: true
        }
    end
  end

  defp log_span_exception(message, config, kind, reason, extra_metadata \\ []) do
    log_lifecycle(
      :error,
      message,
      [
        agent: log_agent_name(config),
        kind: kind,
        reason: format_exception_reason(reason)
      ] ++ extra_metadata
    )
  end

  defp format_exception_reason(reason) do
    if Kernel.is_exception(reason) do
      Exception.message(reason)
    else
      inspect(reason)
    end
  end

  defp log_lifecycle(level, message, metadata) do
    Logger.log(level, message, metadata)
  end

  defp normalize_model_response({response, usage}) when is_map(usage) or is_nil(usage) do
    {response, usage}
  end

  defp normalize_model_response(response), do: {response, nil}

  defp elapsed_ms(started_at) do
    (System.monotonic_time() - started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp token_counts(response) do
    usage =
      cond do
        is_map(response) and usage_map?(response) -> response
        is_map(response) -> Map.get(response, :usage) || Map.get(response, "usage")
        true -> nil
      end

    {usage_value(usage, :input_tokens), usage_value(usage, :output_tokens)}
  end

  defp usage_map?(usage) when is_map(usage) do
    Map.has_key?(usage, :input_tokens) ||
      Map.has_key?(usage, "input_tokens") ||
      Map.has_key?(usage, :output_tokens) ||
      Map.has_key?(usage, "output_tokens")
  end

  defp usage_map?(_usage), do: false

  defp usage_value(nil, _key), do: nil

  defp usage_value(usage, key) do
    case Map.fetch(usage, key) do
      {:ok, value} -> value
      :error -> Map.get(usage, Atom.to_string(key))
    end
  end

  defp raise_llm_call_error({:exception, error, stacktrace}) do
    if Kernel.is_exception(error) do
      reraise(error, stacktrace)
    else
      raise RuntimeError, "LLM call failed: #{inspect({:exception, error})}"
    end
  end

  defp raise_llm_call_error({:exception, error}) do
    if Kernel.is_exception(error) do
      raise RuntimeError, "LLM call failed: #{Exception.message(error)}"
    else
      raise RuntimeError, "LLM call failed: #{inspect({:exception, error})}"
    end
  end

  defp raise_llm_call_error(reason) do
    raise RuntimeError, "LLM call failed: #{inspect(reason)}"
  end

  defp pending_tool_call_count(%BaseAgentConfig{memory: %{history: [latest | _]}})
       when latest.role == "assistant" do
    latest.content
    |> Map.get(:tool_calls, [])
    |> length()
  end

  defp pending_tool_call_count(_), do: 0

  defp completed_iterations({%BaseAgentConfig{memory: %{history: history}}, _response}) do
    assistant_turn_id =
      history
      |> Enum.find_value(fn
        %Message{role: "assistant", turn_id: turn_id} -> turn_id
        _ -> nil
      end)

    history
    |> Enum.count(fn
      %Message{role: "assistant", turn_id: ^assistant_turn_id} -> true
      _ -> false
    end)
  end

  defp completed_iterations(_), do: 0

  defp max_run_iterations(config) do
    if has_tools?(config) do
      config.max_tool_iterations
    else
      1
    end
  end

  defp log_agent_name(%BaseAgentConfig{name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> "unnamed_agent"
      trimmed -> trimmed
    end
  end

  defp log_agent_name(%BaseAgentConfig{name: nil}), do: "unnamed_agent"
  defp log_agent_name(%BaseAgentConfig{name: name}) when is_atom(name), do: Atom.to_string(name)
  defp log_agent_name(%BaseAgentConfig{}), do: "unnamed_agent"

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

  ## MCP Server Management

  @doc """
  Adds an MCP server configuration for server-side MCP.

  The server config is passed to the Anthropic API, which connects
  to the MCP server on your behalf.

  ## Examples

      alias Normandy.MCP.ServerConfig

      server = ServerConfig.new("my_server", "https://mcp.example.com/sse")
      agent = BaseAgent.add_mcp_server(agent, server)

  """
  @spec add_mcp_server(BaseAgentConfig.t(), struct() | map()) :: BaseAgentConfig.t()
  def add_mcp_server(%BaseAgentConfig{mcp_servers: nil} = config, server) do
    %{config | mcp_servers: [server]}
  end

  def add_mcp_server(%BaseAgentConfig{mcp_servers: servers} = config, server) do
    %{config | mcp_servers: servers ++ [server]}
  end

  @doc """
  Discovers and registers client-side MCP tools in the agent's tool registry.

  Connects to an MCP server via the specified adapter, discovers available tools,
  and registers them as Normandy tools that can be used in the agent's tool loop.

  ## Options

    - `:prefix` - Namespace prefix for tool names (e.g., `"my_server"`)

  ## Examples

      agent = BaseAgent.register_mcp_tools(agent, MyAdapter, mcp_client, prefix: "server1")

  """
  @spec register_mcp_tools(BaseAgentConfig.t(), module(), term(), keyword()) ::
          {:ok, BaseAgentConfig.t()} | {:error, term()}
  def register_mcp_tools(%BaseAgentConfig{} = config, adapter, client, opts \\ []) do
    registry = config.tool_registry || Registry.new()

    case Normandy.MCP.Registry.discover_and_register(registry, adapter, client, opts) do
      {:ok, updated_registry} ->
        {:ok, %{config | tool_registry: updated_registry}}

      {:error, _reason} = error ->
        error
    end
  end

  ## Batch Processing

  @doc """
  Process multiple inputs through the agent concurrently.

  Provides efficient batch processing with configurable concurrency.
  Delegates to `Normandy.Batch.Processor.process_batch/3`.

  ## Options

  - `:max_concurrency` - Maximum concurrent tasks (default: 10)
  - `:ordered` - Preserve input order in results (default: true)
  - `:timeout` - Timeout per task in milliseconds (default: 300_000ms)
  - `:on_progress` - Callback function called after each completion
  - `:on_error` - Callback function called on each error

  ## Examples

      # Simple batch
      inputs = [
        %{chat_message: "Hello"},
        %{chat_message: "How are you?"}
      ]
      {:ok, results} = BaseAgent.process_batch(agent, inputs)

      # With options
      {:ok, results} = BaseAgent.process_batch(
        agent,
        inputs,
        max_concurrency: 5
      )

  """
  @spec process_batch(BaseAgentConfig.t(), [term()], keyword()) ::
          {:ok, [term()] | map()}
  def process_batch(agent, inputs, opts \\ []) do
    Normandy.Batch.Processor.process_batch(agent, inputs, opts)
  end

  @doc """
  Process a batch and return detailed statistics.

  Returns success/error breakdown with counts.

  ## Examples

      {:ok, stats} = BaseAgent.process_batch_with_stats(agent, inputs)
      #=> %{
        success: [result1, result2],
        errors: [{input3, error}],
        total: 3,
        success_count: 2,
        error_count: 1
      }

  """
  @spec process_batch_with_stats(BaseAgentConfig.t(), [term()], keyword()) ::
          {:ok, map()}
  def process_batch_with_stats(agent, inputs, opts \\ []) do
    Normandy.Batch.Processor.process_batch_with_stats(agent, inputs, opts)
  end

  # Runs input guardrails and raises Normandy.Guardrails.ViolationError on any
  # violation. Mirrors the input-side raise behaviour of ValidationMiddleware —
  # a rejected input is a hard halt, not a soft pass-through.
  defp run_input_guardrails!(%BaseAgentConfig{input_guardrails: []}, _value), do: :ok

  defp run_input_guardrails!(%BaseAgentConfig{input_guardrails: guards} = config, value) do
    case Normandy.Guardrails.run(guards, value) do
      {:ok, _value} ->
        :ok

      {:error, violations} ->
        emit_guardrail_violation(:input, config, guards, violations)

        raise Normandy.Guardrails.ViolationError,
          message: "Agent input guardrail violation",
          violations: violations
    end
  end

  # Runs output guardrails and logs a warning on violation. Mirrors the
  # output-side log-and-continue behaviour of ValidationMiddleware — we don't
  # want an overzealous pattern to break end-user responses, but operators
  # should still see the event in logs and telemetry.
  defp run_output_guardrails(%BaseAgentConfig{output_guardrails: []}, _value), do: :ok

  defp run_output_guardrails(%BaseAgentConfig{output_guardrails: guards} = config, value) do
    case Normandy.Guardrails.run(guards, value) do
      {:ok, _value} ->
        :ok

      {:error, violations} ->
        emit_guardrail_violation(:output, config, guards, violations)

        IO.warn(
          "Agent output guardrail violation: " <>
            Normandy.Agents.ValidationMiddleware.error_message(violations)
        )

        :ok
    end
  end

  defp emit_guardrail_violation(stage, config, guards, violations, extra_meta \\ %{}) do
    :telemetry.execute(
      [:normandy, :agent, :guardrail, :violation],
      %{count: length(violations)},
      Map.merge(
        %{
          stage: stage,
          agent_name: config.name,
          guards: Enum.map(guards, &guard_module/1),
          violations: violations
        },
        extra_meta
      )
    )
  end

  defp guard_module(mod) when is_atom(mod), do: mod
  defp guard_module({mod, _opts}), do: mod

  # Runs output guardrails on the accumulated text of a streaming final message.
  # Dispatches by mode: :accumulate runs guards after the stream completes
  # (log-and-continue, mirrors non-streaming posture); :incremental is a
  # no-op here because guards already ran at chunk boundaries inside
  # `consume_stream_with_incremental_guards/3`.
  #
  # Returns the final_response with :guardrail_violations populated ([] on pass).
  defp run_streaming_output_guardrails(
         %BaseAgentConfig{output_guardrails: []} = _config,
         final_response,
         _callback
       ) do
    Map.put_new(final_response, :guardrail_violations, [])
  end

  defp run_streaming_output_guardrails(
         %BaseAgentConfig{output_guardrails_streaming_mode: :incremental} = _config,
         final_response,
         _callback
       ) do
    # Guards already ran at chunk boundaries; :guardrail_violations is set.
    Map.put_new(final_response, :guardrail_violations, [])
  end

  defp run_streaming_output_guardrails(
         %BaseAgentConfig{output_guardrails: guards} = config,
         final_response,
         callback
       ) do
    text = extract_streaming_text(final_response)

    case Normandy.Guardrails.run(guards, text) do
      {:ok, _} ->
        Map.put(final_response, :guardrail_violations, [])

      {:error, violations} ->
        emit_guardrail_violation(:output, config, guards, violations, %{
          streaming: true,
          mode: :accumulate
        })

        IO.warn(
          "Agent streaming output guardrail violation: " <>
            Normandy.Agents.ValidationMiddleware.error_message(violations)
        )

        if is_function(callback, 2) do
          callback.(:guardrail_violation, %{
            stage: :output,
            mode: :accumulate,
            violations: violations
          })
        end

        Map.put(final_response, :guardrail_violations, violations)
    end
  end

  # Concatenates text from a streaming final_response's content blocks into a
  # single string. Tool-use blocks and other non-text content are skipped —
  # guardrails on structured content are a non-streaming concern.
  defp extract_streaming_text(%{content: content}) when is_list(content) do
    content
    |> Enum.map_join("", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp extract_streaming_text(_), do: ""
end
