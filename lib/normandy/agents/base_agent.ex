defmodule Normandy.Agents.BaseAgent do
  @moduledoc """
  Core agent implementation providing conversational AI capabilities.

  BaseAgent manages agent state, memory, and LLM interactions through a
  stateful configuration approach.

  `run/3` returns `{:ok, config, output}` or `{:error, exception}` for Normandy's own
  failures (listed on `run/3`) and raises for bugs; `run!/3` returns
  `{config, output}` and raises either way.
  """

  require Logger

  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.ValidationMiddleware
  alias Normandy.Batch.Processor
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.StreamProcessor
  alias Normandy.Components.SystemPromptGenerator
  alias Normandy.Components.ToolCall
  alias Normandy.Hooks.BaseAgentGlue
  alias Normandy.Hooks.Handlers, as: HookHandlers
  alias Normandy.LLM.Call
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLM.OpenAICompatibleAdapter
  alias Normandy.LLMError
  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Resilience.Retry

  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Driver
  alias Normandy.Telemetry.Metadata
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.Telemetry.Provider
  alias Normandy.Telemetry.Request
  alias Normandy.Telemetry.Span
  alias Normandy.Telemetry.Usage
  alias Normandy.Tools.Context
  alias Normandy.Tools.Executor
  alias Normandy.Tools.Registry
  alias Normandy.TurnError

  @type config_input :: %{
          required(:client) => struct(),
          required(:model) => String.t(),
          optional(:temperature) => float() | nil,
          optional(:input_schema) => struct(),
          optional(:output_schema) => struct(),
          optional(:memory) => map(),
          optional(:prompt_specification) => PromptSpecification.t(),
          optional(:max_tokens) => pos_integer(),
          optional(:tool_registry) => Registry.t(),
          optional(:max_tool_iterations) => pos_integer(),
          optional(:max_tool_concurrency) => integer(),
          optional(:retry_options) => keyword(),
          optional(:enable_circuit_breaker) => boolean(),
          optional(:circuit_breaker_options) => keyword(),
          optional(:enable_json_retry) => boolean(),
          optional(:json_retry_max_attempts) => pos_integer(),
          optional(:input_guardrails) => [Normandy.Guardrails.spec()],
          optional(:output_guardrails) => [Normandy.Guardrails.spec()],
          optional(:output_guardrails_streaming_mode) => :accumulate | :incremental,
          optional(:output_guardrails_chunk_size) => pos_integer(),
          optional(:output_guardrails_on_violation) => :block | :warn,
          optional(:name) => String.t() | nil,
          optional(:behaviours) => Normandy.Behaviours.Config.t() | nil,
          optional(:mcp_servers) => [struct() | map()] | nil,
          optional(:tool_context) => map()
        }

  @spec init(config_input()) :: BaseAgentConfig.t()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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

    on_violation = Map.get(config, :output_guardrails_on_violation, :block)

    unless on_violation in [:block, :warn] do
      raise ArgumentError,
            "output_guardrails_on_violation must be :block or :warn, got: #{inspect(on_violation)}"
    end

    tool_context = Map.get(config, :tool_context, %{})

    unless is_map(tool_context) do
      raise ArgumentError,
            "tool_context must be a map of plain data, got: #{inspect(tool_context)}"
    end

    _ =
      validate_compaction_config!(%BaseAgentConfig{
        client: Map.get(config, :client),
        behaviours: Map.get(config, :behaviours, nil)
      })

    _ = validate_client_options!(Map.get(config, :client))
    :ok = validate_policy_opts!(Map.get(config, :behaviours))
    :ok = validate_hooks!(Map.get(config, :behaviours))

    case Map.get(config, :retry_options) do
      nil -> :ok
      retry_options -> Retry.validate_options!(retry_options)
    end

    # Initialize circuit breaker if enabled
    circuit_breaker =
      if Map.get(config, :enable_circuit_breaker, false) do
        cb_opts = Map.get(config, :circuit_breaker_options, [])
        {:ok, cb} = CircuitBreaker.start_link(cb_opts)
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
      temperature: Map.get(config, :temperature),
      max_tokens: max_tokens!(config),
      tool_registry: Map.get(config, :tool_registry, nil),
      max_tool_iterations:
        normalize_max_tool_iterations(Map.get(config, :max_tool_iterations, 5)),
      max_tool_concurrency:
        normalize_max_tool_concurrency(Map.get(config, :max_tool_concurrency, 1)),
      retry_options: Map.get(config, :retry_options, nil),
      circuit_breaker: circuit_breaker,
      enable_json_retry: Map.get(config, :enable_json_retry, true),
      json_retry_max_attempts: Map.get(config, :json_retry_max_attempts, 2),
      mcp_servers: Map.get(config, :mcp_servers, nil),
      name: Map.get(config, :name, nil),
      session_id: Map.get(config, :session_id, nil),
      tool_context: tool_context,
      input_guardrails: input_guardrails,
      output_guardrails: output_guardrails,
      output_guardrails_streaming_mode: streaming_mode,
      output_guardrails_chunk_size: chunk_size,
      output_guardrails_on_violation: on_violation,
      behaviours: Map.get(config, :behaviours, nil)
    }
  end

  @spec reset_memory(BaseAgentConfig.t()) :: BaseAgentConfig.t()
  def reset_memory(%BaseAgentConfig{initial_memory: memory} = config) do
    Map.put(config, :memory, memory)
  end

  @doc """
  Runs the config's input guardrails as a standalone **admission decision** —
  no turn, no memory mutation, no circuit breaker.

  Use this as a pre-charge filter: a host can reject disallowed input before
  paying for an expensive turn. Returns `:ok` to admit, or `{:block, violations}`
  to reject. Unlike the in-turn input check (`run_turn`/streaming admission,
  which raises `Normandy.Guardrails.ViolationError`), `admit/2,3` never raises on
  a violation — the caller decides what to do with a block.

  `context` is threaded to any guard implementing the optional `Guard.check/3`
  callback (see `Normandy.Guardrails.run/3`). The framework treats it as opaque;
  guards that need host data (ids, locale, history) read it, others ignore it.

  Emits `[:normandy, :agent, :guardrail, :decision]` with `outcome` in
  `:admit | :block | :error` (`:error` when the block came from a crashed guard
  under `on_error: :closed`), and on a block the same
  `[:normandy, :agent, :guardrail, :violation]` event as the in-turn path. With
  no input guardrails configured it is a silent `:ok` — no telemetry.
  """
  @spec admit(BaseAgentConfig.t(), term()) ::
          :ok | {:block, [Normandy.Guardrails.Guard.violation()]}
  @spec admit(BaseAgentConfig.t(), term(), map()) ::
          :ok | {:block, [Normandy.Guardrails.Guard.violation()]}
  def admit(config, value, context \\ %{})

  def admit(%BaseAgentConfig{input_guardrails: []}, _value, _context), do: :ok

  def admit(%BaseAgentConfig{input_guardrails: guards} = config, value, context) do
    case Normandy.Guardrails.run(guards, value, context) do
      {:ok, _value} ->
        emit_guardrail_decision(:admit, config, guards, [])
        :ok

      {:error, violations} ->
        emit_guardrail_violation(:input, config, guards, violations)
        emit_guardrail_decision(decision_outcome(violations), config, guards, violations)
        {:block, violations}
    end
  end

  @spec get_response(BaseAgentConfig.t(), struct() | nil) :: struct()
  def get_response(%BaseAgentConfig{} = config, response_model \\ nil) do
    {response, _usage, _meta} = get_response_with_usage(config, response_model)
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

  defp max_tokens!(config) do
    case Map.fetch(config, :max_tokens) do
      :error ->
        BaseAgentConfig.default_max_tokens()

      {:ok, n} when is_integer(n) and n > 0 ->
        n

      {:ok, other} ->
        raise ArgumentError,
              "Normandy.Agents.BaseAgent.init/1: :max_tokens must be a positive integer " <>
                "(the Messages API requires it), got: #{inspect(other)}. Omit it to use " <>
                "the default of #{BaseAgentConfig.default_max_tokens()}."
    end
  end

  # Enforce the `pos_integer()` contract for `:max_tool_iterations`. Unlike
  # `:max_tool_concurrency` (which clamps), we REJECT values < 1: a 0/negative
  # iteration budget is a caller bug with no well-defined turn semantics under
  # the Turn-FSM driver. Non-integers raise for the same reason. Public so the
  # DSL can reuse it, mirroring normalize_max_tool_concurrency/1.
  @doc false
  def normalize_max_tool_iterations(n) when is_integer(n) and n >= 1, do: n

  def normalize_max_tool_iterations(other) do
    raise ArgumentError,
          ":max_tool_iterations must be an integer >= 1, got: #{inspect(other)}"
  end

  # Translate a `Task.async_stream` element into the underlying tool result.
  # `Task.async_stream/3` (the linked variant we use) propagates worker
  # raises to the caller via process-link before the stream yields, so the
  # `{:exit, {exception, stacktrace}}` clause below is unreachable for raises
  # in the current configuration. It IS reachable for `:exit` reasons that
  # the stream catches without killing the caller — most importantly
  # `{:exit, :timeout}` from `on_timeout: :kill_task`, and any deliberate
  # `exit/1` from tool wrapper code. Without this helper those would hit
  # `FunctionClauseError` against a `{:ok, _}`-only pattern, masking the
  # underlying cause. Public (`@doc false`) so it's directly unit-testable.
  @doc false
  def unwrap_tool_task_result!({:ok, result}), do: result

  def unwrap_tool_task_result!({:exit, {exception, stacktrace}})
      when is_exception(exception) and is_list(stacktrace) do
    reraise(exception, stacktrace)
  end

  def unwrap_tool_task_result!({:exit, reason}), do: exit(reason)

  @spec get_response_with_usage(BaseAgentConfig.t(), struct() | nil, keyword()) ::
          {struct(), map() | nil, map()}
  defp get_response_with_usage(
         %BaseAgentConfig{prompt_specification: prompt_specification} = config,
         response_model,
         extra_opts \\ []
       ) do
    response_model =
      if response_model != nil do
        response_model
      else
        Map.get(config, :output_schema)
      end

    # Generate system prompt and add output schema specification
    system_prompt = SystemPromptGenerator.generate_prompt(prompt_specification)

    # Add output schema if available
    system_prompt_with_schema = with_output_schema(system_prompt, response_model)

    tool_schemas =
      if has_tools?(config), do: Registry.to_tool_schemas(config.tool_registry), else: []

    # Thinking is valid only under the system prompt, tools and model that produced
    # it (a context provider, a tool change, the forced final call's schema or a
    # model change can change them), so stale thinking is left out and this call's
    # response is stamped.
    prefix_key = &ToolCallResponse.prefix_key(system_prompt_with_schema, tool_schemas, &1)

    history =
      config.memory
      |> AgentMemory.drop_stale_thinking(prefix_key.(config.model))
      |> AgentMemory.history()

    request = %Normandy.LLM.Request{
      model: config.model,
      system: system_prompt_with_schema,
      messages:
        Enum.map(history, fn %{role: role, content: content} ->
          %Message{role: role, content: content}
        end),
      response_model: response_model,
      temperature: config.temperature,
      max_tokens: config.max_tokens,
      tools: tool_schemas,
      mcp_servers: config.mcp_servers,
      task_budget_remaining: Keyword.get(extra_opts, :task_budget_remaining)
    }

    # How many times the adapter re-asks after a response that does not parse.
    json_retries = if config.enable_json_retry, do: config.json_retry_max_attempts, else: 0

    # Numbers the provider requests of this call (get_response/2 has no llm_call
    # span to create one).
    tracker = Keyword.get_lazy(extra_opts, :request_tracker, fn -> request_tracker(config) end)

    {response, usage, meta} =
      call_llm_with_resilience(config, request,
        json_retries: json_retries,
        request_tracker: tracker
      )

    # After a server-side fallback the thinking kept is the fallback model's.
    produced_by = Map.get(meta, :fallback_model) || config.model
    {stamp_prefix(response, prefix_key.(produced_by)), usage, meta}
  end

  defp stamp_prefix(%ToolCallResponse{} = response, prefix_key),
    do: %{response | prefix_key: prefix_key}

  defp stamp_prefix(response, _prefix_key), do: response

  # Private helper to call LLM with retry and circuit breaker protection.
  # The call returns {:ok, %Response{}} | {:error, %LLMError{}} (Normandy.LLM.Call),
  # which is Retry's and CircuitBreaker's contract, so returned API errors are retried
  # (when the adapter marked them retryable?) and counted, exactly like raises.
  @spec call_llm_with_resilience(BaseAgentConfig.t(), Normandy.LLM.Request.t(), keyword()) ::
          {struct() | String.t(), map() | nil, map()}
  defp call_llm_with_resilience(config, request, opts) do
    tracker = Keyword.get(opts, :request_tracker)

    llm_call = fn ->
      Request.note_call(tracker)
      Call.converse(config.client, request, opts)
    end

    case with_resilience(config, llm_call) do
      {:ok, %Normandy.LLM.Response{content: content, usage: usage, meta: meta}} ->
        {content, usage, meta}

      # Retry gave up: {last_error, attempts, errors}. The integer guard keeps
      # {:exception, error, stacktrace} (also a 3-tuple) out of this clause.
      {:error, {reason, attempts, errors}} when is_integer(attempts) and is_list(errors) ->
        raise_llm_call_error(reason)

      {:error, reason} ->
        raise_llm_call_error(reason)
    end
  end

  # Retry (retry_options) inside the circuit breaker (circuit_breaker), each only
  # when configured. `may_retry?` is checked before each retry on top of the
  # retry_if policy; streaming uses it to stop once output reached the caller.
  defp with_resilience(config, call, may_retry? \\ fn -> true end) do
    retryable_call =
      if config.retry_options do
        retry_opts = retry_options(config.retry_options, may_retry?)
        fn -> Retry.with_retry(call, retry_opts) end
      else
        call
      end

    if config.circuit_breaker do
      CircuitBreaker.call(config.circuit_breaker, retryable_call)
    else
      retryable_call.()
    end
  end

  defp retry_options(retry_options, may_retry?) do
    retry_options
    |> with_default_retry_if()
    |> Keyword.update!(:retry_if, &fn result -> may_retry?.() and &1.(result) end)
  end

  defp with_default_retry_if(retry_options) do
    if Keyword.has_key?(retry_options, :retry_if),
      do: retry_options,
      else: Keyword.put(retry_options, :retry_if, &default_retry_if/1)
  end

  defp default_retry_if({:error, %LLMError{retryable?: retryable?}}), do: retryable?
  defp default_retry_if({:error, {:exception, _, _}}), do: true
  defp default_retry_if({:error, :open}), do: false
  defp default_retry_if(_), do: false

  @doc """
  Runs one turn: validates `user_input` against the input schema, calls the model (and
  the tools it asks for, when the agent has tools) and returns the answer converted to
  the output schema.

  Returns `{:ok, config, output}`, where `config` holds the turn in its memory, or
  `{:error, exception}` when Normandy's own checks or the model failed:
  `Normandy.LLMError`, `Normandy.Schema.ValidationError`,
  `Normandy.Guardrails.ViolationError`, `Normandy.HookHaltError`,
  `Normandy.ModelCatalogError` or `Normandy.TurnError`. Any other exception (a bug in a
  tool, a hook under `on_error: :reraise`, a client) is raised. On `{:error, _}` the
  turn is lost: keep using the config you passed in.

  `user_input` may be `nil` to continue the conversation without a new user message.

  Accepts `opts`:
  - `:stream` - Boolean, enables streaming mode
  - `:on_chunk` - Callback function for streaming chunks (required with `stream: true`)

  ## Example

      {:ok, agent, response} = BaseAgent.run(agent, %{chat_message: "Hello"})

      {:ok, agent, response} =
        BaseAgent.run(agent, %{chat_message: "Hello"}, stream: true, on_chunk: &IO.write/1)
  """
  @spec run(BaseAgentConfig.t(), term(), keyword()) ::
          {:ok, BaseAgentConfig.t(), term()} | {:error, Exception.t()}
  def run(config, user_input \\ nil, opts \\ []) do
    {config, output} = run!(config, user_input, opts)
    {:ok, config, output}
  rescue
    e -> if TurnError.domain?(e), do: {:error, e}, else: reraise(e, __STACKTRACE__)
  end

  @doc """
  Like `run/3`, but returns `{config, output}` and raises the exception `run/3` would
  return.
  """
  @spec run!(BaseAgentConfig.t(), term(), keyword()) :: {BaseAgentConfig.t(), term()}
  def run!(config, user_input \\ nil, opts \\ [])

  def run!(%BaseAgentConfig{tool_registry: tool_registry} = config, user_input, []) do
    metadata = Metadata.run(config)

    with_agent_run_span(config, metadata, fn ->
      result =
        if tool_registry != nil && Registry.count(tool_registry) > 0 do
          # Call the private run_turn/2 directly, NOT the public run_with_tools/2:
          # run_with_tools/2 now opens its own agent.run span, so routing through
          # it here would double-wrap and emit two nested agent.run spans.
          run_turn(config, user_input)
        else
          # No tools registered, use simple response
          run_without_tools(config, user_input)
        end

      {result, metadata}
    end)
  end

  # Matches the config too: with no stream this clause calls run!/3 with [], and a
  # non-config must fail with FunctionClauseError here, not re-enter it forever.
  def run!(%BaseAgentConfig{} = config, user_input, opts) when is_list(opts) do
    stream = Keyword.get(opts, :stream, false)
    on_chunk = Keyword.get(opts, :on_chunk)

    if stream and on_chunk do
      metadata = Metadata.run(config)

      # Convert arity-1 callback to arity-2 if needed
      callback =
        if is_function(on_chunk, 1) do
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          fn
            :text_delta, text -> on_chunk.(text)
            _, _ -> :ok
          end
        else
          on_chunk
        end

      # stream_with_tools/3 and stream_response/3 are both run_stream_turn/3 (the
      # tool loop is the FSM's), and each opens its own run span, so call the
      # private turn here to keep a single span.
      with_agent_run_span(config, metadata, fn ->
        {run_stream_turn(config, user_input, callback), metadata}
      end)
    else
      if stream do
        raise ArgumentError,
              "BaseAgent.run/3: stream: true requires :on_chunk (a 1- or 2-arity callback)"
      end

      run!(config, user_input, [])
    end
  end

  # Private function for simple runs without tool support.
  # Delegates to the Turn FSM production interpreter (Phase 1c).
  defp run_without_tools(config, user_input) do
    run_turn(config, user_input)
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
  def run_with_tools(config, user_input \\ nil) do
    metadata = Metadata.run(config)

    with_agent_run_span(config, metadata, fn ->
      {run_turn(config, user_input), metadata}
    end)
  end

  @doc false
  def unwrap_llm_content(content) when is_binary(content) do
    case Application.get_env(:normandy, :adapter, Poison).decode(content) do
      {:ok, %{"chat_message" => text}} when is_binary(text) -> text
      _ -> content
    end
  end

  @doc false
  def unwrap_llm_content(content), do: content

  # ── Turn FSM production interpreter (Phase 1c, non-streaming) ────────────────
  #
  # Synchronous shell that drives the pure `Normandy.Agents.Turn` core to a stop,
  # threading the running %BaseAgentConfig{} (the memory accumulator) alongside
  # the FSM state and performing each effect via the existing BaseAgent helpers.
  # Returns {config, final_response}. Input validation + guardrails + memory init
  # are admission control performed before :start (they raise on failure, as the
  # pre-FSM loop did). Order: schema validation, on_prompt hooks (a rewrite is
  # re-validated), then input guardrails. LLM failures raise inside the :call_llm handler
  # (parity: exceptions propagate out of run!/3; run/3 returns the domain ones), so the
  # FSM's :failed path is only reached on an unexpected event-sequencing bug.

  @spec run_turn(BaseAgentConfig.t(), struct() | map() | nil) ::
          {BaseAgentConfig.t(), struct()}
  defp run_turn(config, user_input) do
    config = admit_turn_input(config, user_input)

    state =
      Turn.new(
        max_iterations: config.max_tool_iterations,
        response_model: turn_response_model(config),
        output_schema: config.output_schema
      )

    {config, final_state} = drive_turn(config, state)
    {config, final_state.final_response}
  end

  @doc false
  def turn_response_model(config) do
    if has_tools?(config) do
      %Normandy.Agents.ToolCallResponse{}
    else
      config.output_schema
    end
  end

  @doc false
  def admit_turn_input(config, nil), do: config

  def admit_turn_input(config, user_input),
    do: begin_turn(config, admit_input!(config, user_input))

  @doc false
  # Admission without the memory append, so Turn.Server can admit a turn's input before
  # it repairs an interrupted batch: schema validation, on_prompt hooks on the validated
  # input, validation of a rewritten input, input guardrails. Raises
  # Normandy.Schema.ValidationError, Normandy.HookHaltError or
  # Normandy.Guardrails.ViolationError; returns the admitted input.
  @spec admit_input!(BaseAgentConfig.t(), term()) :: term()
  def admit_input!(_config, nil), do: nil

  def admit_input!(config, user_input) do
    validated = validate_turn_input!(config, user_input)

    # A rewrite is validated like a caller's input: a plain map or another struct is
    # cast and checked against the input schema; a value already of the schema's struct
    # is trusted, as a caller's is (ValidationMiddleware.validate_input/2).
    admitted =
      case BaseAgentGlue.prompt!(config, validated) do
        ^validated -> validated
        rewritten -> validate_turn_input!(config, rewritten)
      end

    run_input_guardrails!(config, admitted)
    admitted
  end

  @doc false
  # Starts the turn in memory with an admitted input.
  @spec begin_turn(BaseAgentConfig.t(), term()) :: BaseAgentConfig.t()
  def begin_turn(config, nil), do: config

  def begin_turn(config, admitted) do
    updated_memory =
      config.memory
      |> AgentMemory.initialize_turn()
      |> AgentMemory.add_message("user", admitted)

    config
    |> Map.put(:current_user_input, admitted)
    |> Map.put(:memory, updated_memory)
  end

  defp validate_turn_input!(config, user_input) do
    case ValidationMiddleware.validate_input(config, user_input) do
      {:ok, validated} ->
        validated || user_input

      {:error, errors} ->
        raise Normandy.Schema.ValidationError,
          message: "Agent input validation failed",
          errors: errors,
          details: ValidationMiddleware.error_message(errors)
    end
  end

  defp drive_turn(%BaseAgentConfig{} = config, %Turn.State{} = state) do
    Driver.drive(state, HookHandlers.wrap(non_streaming_handlers(), config), config)
  end

  @doc false
  def non_streaming_handlers do
    %Driver.Handlers{
      call_llm: &call_turn_llm/3,
      dispatch_tools: &dispatch_turn_tools/2,
      convert: &convert_turn_output/3,
      validate: &validate_turn_output/2,
      guard: &run_output_guardrails/2,
      append: fn config, role, content ->
        Map.put(config, :memory, AgentMemory.add_message(config.memory, role, content))
      end,
      compact: &compact_turn_memory/3,
      emit: &emit_turn_event/3
    }
  end

  # Effect handlers ────────────────────────────────────────────────────────────

  # Task budget (client.options[:task_budget]): before any in-turn compaction the
  # server tracks the countdown, so only `total` goes out. After compaction removed
  # messages, the server can no longer count them: send
  # remaining = total - this turn's tokens removed (gross), the same value on every
  # later call in the turn (Anthropic task-budgets doc). Map.get: a Turn.State
  # persisted by Normandy < 2.0 has no :tokens_compacted key.
  defp task_budget_call_opts(%BaseAgentConfig{client: %{options: %{task_budget: total}}}, state)
       when is_integer(total) do
    case Map.get(state, :tokens_compacted, 0) do
      0 -> []
      compacted -> [task_budget_remaining: max(total - compacted, 0)]
    end
  end

  defp task_budget_call_opts(_config, _state), do: []

  defp call_turn_llm(config, state, %{response_model: response_model}) do
    iteration = config.max_tool_iterations - state.iterations_left + 1

    llm_metadata =
      %{model: config.model, iteration: iteration, agent_name: config.name}
      |> Map.merge(Metadata.ids(config))
      |> Map.merge(
        Provider.request_metadata(config,
          stream: false,
          response_model: response_model || Map.get(config, :output_schema),
          tools?: has_tools?(config)
        )
      )

    with_llm_call_span(config, llm_metadata, fn ->
      tracker = request_tracker(config)

      {r, usage, response_meta} =
        get_response_with_usage(
          config,
          response_model,
          [request_tracker: tracker] ++ task_budget_call_opts(config, state)
        )

      # When this agent has no tools, strip any tool_calls the LLM may have
      # returned (e.g. a misbehaving or generic mock). Old run_without_tools
      # never inspected tool_calls on the response, so the FSM must not see
      # them either — this preserves the no-tools parity contract.
      r =
        case {has_tools?(config), r} do
          {false, %{tool_calls: [_ | _]}} -> Map.put(r, :tool_calls, [])
          _ -> r
        end

      tool_calls = Map.get(r, :tool_calls) || []

      meta =
        llm_metadata
        |> Map.merge(%{
          has_tool_calls: tool_calls != [],
          tool_call_count: length(tool_calls),
          usage: usage
        })
        |> Map.merge(
          Map.take(response_meta, [
            :served_by,
            :input_transformations,
            :response_id,
            :finish_reason
          ])
          |> normalize_finish_reason()
        )
        |> Map.merge(Request.summary(tracker))

      {r, meta}
    end)
  end

  # The [:normandy, :llm, :request] counter for one llm_call; its request spans
  # carry the call's ids.
  defp request_tracker(config) do
    config
    |> Metadata.ids()
    |> Map.put(:agent_name, config.name)
    |> Request.new()
  end

  defp dispatch_turn_tools(config, calls) do
    parent_otel_ctx = OtelCtx.capture()
    max_concurrency = max(config.max_tool_concurrency || 1, 1)

    calls
    |> Task.async_stream(
      fn call ->
        OtelCtx.restore(parent_otel_ctx)
        execute_one_tool_call(config, call)
      end,
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Enum.map(&unwrap_tool_task_result!/1)
  end

  # Mirror of execute_tool_loop's no-tool-call conversion (old ~:562-580).
  # Called only when convert_needed? is true (the tool-loop case). The FSM passes
  # s.output_schema (== config.output_schema, seeded in run_turn and never mutated)
  # as the third arg; we use it directly rather than reaching back into config.
  # For a chat_message schema we map the unwrapped content into it; for any other
  # schema we return the raw response (parity with the no-tools finalize path).
  defp convert_turn_output(_config, raw, output_schema) do
    if raw.content && raw.content != "" do
      case output_schema do
        %{chat_message: _} ->
          Map.put(output_schema, :chat_message, unwrap_llm_content(raw.content))

        _ ->
          raw
      end
    else
      output_schema
    end
  end

  # Mirror of the soft validate_output handling (old ~:415-428 / ~:583-597).
  defp validate_turn_output(config, value) do
    alias Normandy.Agents.ValidationMiddleware

    case ValidationMiddleware.validate_output(config, value) do
      {:ok, validated} ->
        validated || value

      {:error, errors} ->
        error_msg = ValidationMiddleware.error_message(errors)
        IO.warn("Agent output validation failed: #{error_msg}\nReceived: #{inspect(value)}")
        value
    end
  end

  # Reproduces the per-iteration debug log the old tool loop emitted (~:539).
  # Gated on has_tools? because the old run_without_tools did NOT emit this
  # line; the FSM emits :iteration even for no-tools turns, so we suppress it
  # here to preserve logging parity for the no-tools path.
  defp emit_turn_event(config, :iteration, %{iteration: iteration}) do
    if has_tools?(config) do
      log_lifecycle(:debug, "normandy agent iteration",
        agent: log_agent_name(config),
        iteration: iteration,
        pending_tool_calls: pending_tool_call_count(config)
      )
    end
  end

  defp emit_turn_event(_config, _name, _meta), do: :ok

  # Compaction at the :steering boundary. Resolves the configured Compactor and
  # the model's context window (pinned `:max_tokens`, else the configured
  # ModelCatalog, memoised on the config), compacts the running config.memory,
  # and logs when it actually shrinks the conversation. Every run emits
  # [:normandy, :agent, :compaction] (measurements: whichever of :tokens_before,
  # :tokens_after, :tokens_removed the compactor reported; metadata: :agent_name,
  # :model, :strategy, :compacted, and the compactor's :error / :reason when it
  # failed or could not size a window), so a compactor that never fires is observable.
  # The default config selects Compactor.NoOp, so this is observably a no-op
  # unless an agent opts into a real compactor.
  @doc false
  def compact_turn_memory(%BaseAgentConfig{} = config, %Turn.State{} = _state, info) do
    {mod, opts} = compactor_ref(config)
    {config, window} = resolve_context_window(config, mod, opts)
    ctx = %{model: config.model, window: window}
    {config2, meta} = mod.maybe_compact(config, ctx, opts)

    :telemetry.execute(
      [:normandy, :agent, :compaction],
      Map.take(meta, [:tokens_before, :tokens_after, :tokens_removed]),
      %{
        agent_name: config.name,
        model: config.model,
        strategy: Map.get(meta, :strategy),
        compacted: Map.get(meta, :compacted) == true,
        error: Map.get(meta, :error),
        reason: Map.get(meta, :reason)
      }
    )

    if Map.get(meta, :compacted) do
      log_lifecycle(:debug, "normandy agent compaction",
        agent: log_agent_name(config),
        iterations_left: Map.get(info, :iterations_left),
        tokens_before: Map.get(meta, :tokens_before),
        tokens_after: Map.get(meta, :tokens_after),
        strategy: Map.get(meta, :strategy)
      )
    end

    {config2, meta}
  end

  defp compactor_ref(%BaseAgentConfig{behaviours: %Normandy.Behaviours.Config{compactor: ref}})
       when not is_nil(ref),
       do: ref

  defp compactor_ref(_config), do: {Normandy.Behaviours.Compactor.NoOp, []}

  @doc false
  # Fail at configuration time on an invalid adapter `client.options`, instead of
  # on every call (where the retry policy would wait through its backoff first).
  @spec validate_client_options!(term()) :: term()
  def validate_client_options!(%Normandy.LLM.ClaudioAdapter{} = client),
    do: ClaudioAdapter.validate_options!(client)

  def validate_client_options!(%OpenAICompatibleAdapter{} = client),
    do: OpenAICompatibleAdapter.validate_options!(client)

  def validate_client_options!(client), do: client

  # A policy whose module checks its opts (the optional
  # PolicyEngine.validate_opts!/1) raises here, where the config is made.
  defp validate_policy_opts!(%Config{policy: {mod, opts}}) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :validate_opts!, 1),
      do: mod.validate_opts!(opts),
      else: :ok
  end

  defp validate_policy_opts!(_behaviours), do: :ok

  # Hook entries are checked where the config is made, like the policy's opts.
  defp validate_hooks!(%Config{hooks: hooks}),
    do: Hooks.validate_entries!(hooks)

  defp validate_hooks!(_behaviours), do: :ok

  @doc false
  # A real compactor sizes against the model's context window. With no pinned
  # :max_tokens and the default catalog (the Anthropic Models API), that lookup
  # needs a ClaudioAdapter client; any other client makes every compaction raise
  # mid-turn, after tools ran. Called from init/1 and ConfigTemplate.rebuild/3 so
  # the mistake surfaces where the config is made. Never inspects the client value
  # (it may hold an API key), only its struct name.
  # Takes any %BaseAgentConfig{}: init/1 validates a partial one (client + behaviours only).
  @spec validate_compaction_config!(BaseAgentConfig.partial()) :: BaseAgentConfig.partial()
  def validate_compaction_config!(%BaseAgentConfig{} = config) do
    {compactor, compactor_opts} = compactor_ref(config)
    {catalog, _catalog_opts} = catalog_ref(config)

    unless Keyword.keyword?(compactor_opts) do
      raise ArgumentError,
            "Normandy.Agents.BaseAgent.validate_compaction_config!/1: opts for compactor " <>
              "#{inspect(compactor)} must be a keyword list, got #{inspect(compactor_opts)}"
    end

    needs_api_lookup? =
      compactor != Normandy.Behaviours.Compactor.NoOp and
        not Keyword.has_key?(compactor_opts, :max_tokens) and
        catalog in [
          Normandy.Behaviours.ModelCatalog.ModelsAPI,
          Normandy.Behaviours.ModelCatalog.Static
        ]

    if needs_api_lookup? and not match?(%Normandy.LLM.ClaudioAdapter{}, config.client) do
      raise ArgumentError,
            "Normandy.Agents.BaseAgent: compactor #{inspect(compactor)} needs the model's " <>
              "context window, and the model catalog #{inspect(catalog)} reads it from the " <>
              "Anthropic Models API, which needs a Normandy.LLM.ClaudioAdapter client; got " <>
              "#{client_kind(config.client)}. Pin the window with the compactor's :max_tokens " <>
              "option, or configure a model_catalog that works with this client."
    end

    config
  end

  defp client_kind(%{__struct__: mod}), do: "a #{inspect(mod)}"
  defp client_kind(nil), do: "nil"
  defp client_kind(other) when is_map(other), do: "a plain map"
  defp client_kind(_other), do: "a non-struct value"

  # The window the compactor sizes against. NoOp needs none; a pinned
  # :max_tokens wins without a lookup (offline use, non-Claude clients);
  # otherwise the catalog, memoised per model on the config. A failed lookup
  # fails the turn: the agent asked for compaction and can't size it.
  defp resolve_context_window(config, Normandy.Behaviours.Compactor.NoOp, _opts),
    do: {config, nil}

  defp resolve_context_window(config, _compactor, opts) do
    case Keyword.fetch(opts, :max_tokens) do
      {:ok, pinned} -> {config, pinned}
      :error -> lookup_context_window(config)
    end
  end

  defp lookup_context_window(
         %BaseAgentConfig{model: model, resolved_context_window: {model, window}} = config
       ),
       do: {config, window}

  defp lookup_context_window(%BaseAgentConfig{model: model} = config) do
    {catalog_mod, catalog_opts} = catalog_ref(config)

    case catalog_mod.context_window(model, with_catalog_client(config, catalog_opts)) do
      # Map.put: a BaseAgentConfig built under 1.x has no :resolved_context_window key.
      {:ok, window} when is_integer(window) and window > 0 ->
        {Map.put(config, :resolved_context_window, {model, window}), window}

      # A custom catalog's bad value must not be memoised or reach the compactor.
      {:ok, other} ->
        raise Normandy.ModelCatalogError,
          model: model,
          reason: {:invalid_context_window, other}

      {:error, reason} ->
        raise Normandy.ModelCatalogError, model: model, reason: reason
    end
  end

  defp with_catalog_client(
         %BaseAgentConfig{client: %Normandy.LLM.ClaudioAdapter{} = client},
         opts
       ),
       do:
         Keyword.put_new_lazy(opts, :client, fn ->
           ClaudioAdapter.to_claudio_client(client)
         end)

  defp with_catalog_client(_config, opts), do: opts

  defp catalog_ref(%BaseAgentConfig{behaviours: %Normandy.Behaviours.Config{model_catalog: ref}})
       when not is_nil(ref),
       do: ref

  defp catalog_ref(_config), do: {Normandy.Behaviours.ModelCatalog.ModelsAPI, []}

  # ── End Turn FSM production interpreter ──────────────────────────────────────

  # Streaming analog of run_turn/2. Admission (input guardrails + memory init,
  # NO schema validation — streaming parity) before Turn.step(:start), then drive
  # the FSM with the streaming handler set. Returns {config, final_response}; the
  # synthetic :tool_calls key (added so the FSM could branch) and the :prefix_key
  # stamp are stripped from the returned response. A thrown stream error is raised
  # as a Normandy.LLMError.
  defp run_stream_turn(config, user_input, callback) when is_function(callback, 2) do
    config = admit_stream_turn_input(config, user_input)

    state =
      Turn.new(
        max_iterations: config.max_tool_iterations,
        response_model: turn_response_model(config),
        output_schema: config.output_schema
      )

    try do
      {config, final_state} =
        Driver.drive(state, HookHandlers.wrap(streaming_handlers(callback), config), config)

      {config, Map.drop(final_state.final_response, [:tool_calls, :prefix_key])}
    catch
      {:stream_turn_error, error} ->
        raise LLMError.wrap(error)
    end
  end

  # Streaming admits input exactly as run/2 does: on_prompt hooks (with the rewrite
  # re-validated), input guardrails, then the memory turn.
  defp admit_stream_turn_input(config, user_input), do: admit_turn_input(config, user_input)

  # ── Streaming Turn FSM handlers (Phase 1d) ───────────────────────────────────

  @doc false
  def streaming_handlers(callback) do
    %Driver.Handlers{
      call_llm: fn config, state, _request -> call_stream_llm(config, state, callback) end,
      dispatch_tools: fn config, calls -> dispatch_stream_tools(config, calls, callback) end,
      convert: fn _config, raw, _output_schema -> raw end,
      # Output guardrails run in the `validate` slot, NOT `guard`: the driver
      # threads `validate`'s return value forward (so the :guardrail_violations
      # tag that run_streaming_output_guardrails attaches survives onto the
      # returned response), but DISCARDS `guard`'s return. Do not swap these —
      # moving guardrails to `guard` would silently drop the violations tag.
      validate: fn config, value -> run_streaming_output_guardrails(config, value, callback) end,
      guard: fn _config, _value -> :ok end,
      append: fn config, role, content -> append_stream_message(config, role, content) end,
      compact: &compact_turn_memory/3,
      emit: &emit_turn_event/3
    }
  end

  # Streams one LLM call to a final message, augmenting it with a :tool_calls key
  # so the pure FSM (which branches on .tool_calls) can dispatch. Tool calls are
  # stripped for no-tools agents (parity: stream_response never executed tools),
  # mirroring call_turn_llm's no-tools strip. A stream failure is thrown past the
  # driver (from inside the llm_call span, so the span emits :exception) and
  # caught in run_stream_turn/3, which raises the wrapped LLMError.
  defp call_stream_llm(config, state, callback) do
    iteration = config.max_tool_iterations - state.iterations_left + 1

    llm_metadata =
      %{model: config.model, iteration: iteration, agent_name: config.name}
      |> Map.merge(Metadata.ids(config))
      |> Map.merge(
        Provider.request_metadata(config,
          stream: true,
          response_model: nil,
          tools?: has_tools?(config)
        )
      )

    final_message =
      with_llm_call_span(config, llm_metadata, fn ->
        stream_llm_attempt(config, state, callback, llm_metadata)
      end)

    tool_calls = if has_tools?(config), do: extract_tool_calls(final_message) || [], else: []
    Map.put(final_message, :tool_calls, tool_calls)
  end

  # Runs inside the llm_call span: a failed stream throws here so the span emits
  # :exception rather than :stop.
  defp stream_llm_attempt(config, state, callback, llm_metadata) do
    {request, prefix_key} = build_stream_request(config)

    request = %{
      request
      | task_budget_remaining:
          Keyword.get(task_budget_call_opts(config, state), :task_budget_remaining)
    }

    {callback, first_chunk} = track_first_chunk(callback)
    tracker = request_tracker(config)

    case stream_response_from_llm(config, request, callback, first_chunk, tracker) do
      {:ok, final_message} ->
        # The prefix this response was produced under, stamped when it is appended.
        final_message = Map.put(final_message, :prefix_key, prefix_key)
        tcs = if has_tools?(config), do: extract_tool_calls(final_message) || [], else: []

        {final_message,
         llm_metadata
         |> Map.merge(%{has_tool_calls: tcs != [], tool_call_count: length(tcs)})
         |> Map.merge(stream_meta(final_message))
         |> Map.merge(first_chunk_meta(first_chunk))
         |> Map.merge(Request.summary(tracker))
         |> put_usage(Map.get(final_message, :usage))}

      {:error, error} ->
        # Only the error: the span's exception log and telemetry inspect the thrown
        # term, and the config holds the client.
        throw({:stream_turn_error, error})
    end
  end

  # The streamed counterpart of the adapter's response_meta/1. Streaming calls
  # cannot use :fallbacks, so message_start's model is the one that served.
  defp stream_meta(final_message) do
    served_by =
      case Map.get(final_message, :model) do
        model when is_binary(model) -> %{served_by: model}
        _ -> %{}
      end

    served_by =
      served_by
      |> put_present(:response_id, Map.get(final_message, :id))
      |> put_present(:finish_reason, finish_reason(Map.get(final_message, :stop_reason)))

    case Map.get(final_message, :input_transformations) do
      [_ | _] = transformations -> Map.put(served_by, :input_transformations, transformations)
      _ -> served_by
    end
  end

  # One type for consumers: the provider's stop reason as a string.
  defp finish_reason(nil), do: nil
  defp finish_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp finish_reason(reason), do: reason

  defp normalize_finish_reason(%{finish_reason: reason} = meta),
    do: Map.put(meta, :finish_reason, finish_reason(reason))

  defp normalize_finish_reason(meta), do: meta

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Wraps the stream callback to note when the first content chunk (a text delta,
  # a thinking delta or a tool-use start; not message_start/stop) arrives.
  # Returns the wrapped callback and a tracker: an atomics array whose slot 1 holds
  # the elapsed native time + 1 (0 = not seen) and slot 2 the start of the current
  # attempt, which mark_attempt_start/1 resets so retry backoff is not counted.
  defp track_first_chunk(callback) when is_function(callback, 2) do
    tracker = :atomics.new(2, [])
    mark_attempt_start(tracker)

    wrapped = fn event, data ->
      if event in [:text_delta, :thinking_delta, :tool_use_start] and
           :atomics.get(tracker, 1) == 0 do
        :atomics.put(tracker, 1, System.monotonic_time() - :atomics.get(tracker, 2) + 1)
      end

      callback.(event, data)
    end

    {wrapped, tracker}
  end

  defp track_first_chunk(callback), do: {callback, nil}

  defp mark_attempt_start(nil), do: :ok
  defp mark_attempt_start(tracker), do: :atomics.put(tracker, 2, System.monotonic_time())

  defp first_chunk_meta(nil), do: %{}

  defp first_chunk_meta(tracker) do
    case :atomics.get(tracker, 1) do
      0 -> %{}
      elapsed -> %{time_to_first_chunk: elapsed - 1}
    end
  end

  # Mirror of dispatch_turn_tools with the streaming per-tool :tool_result
  # callback. Same Task.async_stream parallelism + OtelCtx propagation.
  defp dispatch_stream_tools(config, calls, callback) do
    parent_otel_ctx = OtelCtx.capture()
    max_concurrency = max(config.max_tool_concurrency || 1, 1)

    calls
    |> Task.async_stream(
      fn call ->
        OtelCtx.restore(parent_otel_ctx)
        result = execute_one_streaming_tool_call(config, call)
        callback.(:tool_result, result)
        result
      end,
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Enum.map(&unwrap_tool_task_result!/1)
  end

  # Assistant turns are persisted as a %ToolCallResponse{} built from content
  # blocks so tool_use survives AgentMemory.history/1 re-serialization; any
  # :guardrail_violations is dropped (build produces a fresh struct without it),
  # as is the synthetic :tool_calls key added in call_stream_llm/3 for FSM
  # branching (the fresh struct doesn't carry it through persistence).
  # Other roles (e.g. "tool") persist their content unchanged.
  defp append_stream_message(config, "assistant", content) do
    tool_calls = extract_tool_calls(content) || []
    message = build_streaming_assistant_response(content, tool_calls)
    Map.put(config, :memory, AgentMemory.add_message(config.memory, "assistant", message))
  end

  defp append_stream_message(config, role, content) do
    Map.put(config, :memory, AgentMemory.add_message(config.memory, role, content))
  end

  # ── End streaming Turn FSM handlers ──────────────────────────────────────────

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

  ## Raises
    `Normandy.LLMError` when the stream fails to start, carries an `error` event
    or `{:error, _}` item, or ends without `message_stop`.

  ## Compared with `run/2`
    - Input goes through the same schema validation and input guardrails.
    - `retry_options` and the circuit breaker apply, but a stream is retried only
      until its first event reaches the callback, so no output is shown twice.
    - The final response is the accumulated message map; it is not converted to
      the output schema.

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
    metadata = Metadata.run(config)

    with_agent_run_span(config, metadata, fn ->
      {run_stream_turn(config, user_input, callback), metadata}
    end)
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

  ## Raises
    `Normandy.LLMError` when the stream fails to start, carries an `error` event
    or `{:error, _}` item, or ends without `message_stop`. Streams are not retried.

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
  def stream_with_tools(config = %BaseAgentConfig{}, user_input \\ nil, callback)
      when is_function(callback, 2) do
    metadata = Metadata.run(config)

    with_agent_run_span(config, metadata, fn ->
      {run_stream_turn(config, user_input, callback), metadata}
    end)
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
  defp build_streaming_assistant_response(%{content: content} = response, tool_calls)
       when is_list(content) do
    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", &Map.get(&1, "text", ""))

    calls =
      Enum.map(tool_calls || [], fn block ->
        %ToolCall{
          id: block["id"],
          name: block["name"],
          input: Dispatch.normalize_tool_input(block["input"])
        }
      end)

    %ToolCallResponse{
      content: if(text == "", do: nil, else: text),
      tool_calls: calls,
      thinking: ToolCallResponse.thinking_blocks(content),
      prefix_key: Map.get(response, :prefix_key)
    }
  end

  defp build_streaming_assistant_response(other, _), do: other

  # Appends the response schema's JSON Schema to the system prompt. A struct with
  # no schema adds nothing; an encoding failure raises rather than silently
  # sending the prompt without its schema.
  defp with_output_schema(system_prompt, nil), do: system_prompt

  # ToolCallResponse is the adapter's internal shape for a tool-loop reply; tool calls
  # travel through the API's `tools` parameter. Showing its schema made models write
  # that shape as their text answer, which then landed verbatim in chat_message.
  defp with_output_schema(system_prompt, %Normandy.Agents.ToolCallResponse{}), do: system_prompt

  defp with_output_schema(system_prompt, response_model) do
    case Normandy.Schema.json_schema(response_model) do
      nil ->
        system_prompt

      schema ->
        schema_json =
          Application.get_env(:normandy, :adapter, Poison).encode!(schema, pretty: true)

        system_prompt <>
          "\n\n# OUTPUT SCHEMA\nRespond with a JSON object that matches this schema, using exactly these field names and no others:\n```json\n#{schema_json}\n```"
    end
  end

  # The request for a streaming LLM call, with thinking left out where the system
  # prompt or tools changed since it was produced (see get_response_with_usage/3),
  # and the prefix key this request runs under.
  defp build_stream_request(config) do
    system_prompt = SystemPromptGenerator.generate_prompt(config.prompt_specification)

    tool_schemas =
      if has_tools?(config), do: Registry.to_tool_schemas(config.tool_registry), else: []

    # Streaming calls cannot use :fallbacks, so the requested model produces it.
    prefix_key = ToolCallResponse.prefix_key(system_prompt, tool_schemas, config.model)

    messages =
      config.memory
      |> AgentMemory.drop_stale_thinking(prefix_key)
      |> AgentMemory.history()
      |> Enum.map(fn %{role: role, content: content} ->
        %Message{role: role, content: content}
      end)

    request = %Normandy.LLM.Request{
      model: config.model,
      system: system_prompt,
      messages: messages,
      temperature: config.temperature,
      max_tokens: config.max_tokens,
      tools: tool_schemas,
      mcp_servers: config.mcp_servers
    }

    {request, prefix_key}
  end

  # Retry and the circuit breaker cover a stream like a non-streaming call, but
  # a stream is retried only until its first event reaches the callback: after
  # that the caller has seen output, and a retry would show it twice.
  # Each attempt is one [:normandy, :llm, :request] span, emitted here because the
  # stream is consumed here (adapters emit none for stream/3).
  defp stream_response_from_llm(config, request, callback, first_chunk, tracker) do
    delivered = :atomics.new(1, [])
    callback = track_delivery(callback, delivered)

    request_metadata = %{
      model: config.model,
      provider: Provider.provider(config.client),
      stream: true
    }

    attempt = fn ->
      mark_attempt_start(first_chunk)
      Request.note_call(tracker)

      Request.span(
        tracker,
        nil,
        request_metadata,
        fn -> stream_attempt(config, request, callback) end,
        &stream_request_outcome/1
      )
    end

    case with_resilience(config, attempt, fn -> :atomics.get(delivered, 1) == 0 end) do
      {:ok, _final} = ok ->
        ok

      {:error, %LLMError{} = error} ->
        {:error, error}

      {:error, {reason, attempts, errors}} when is_integer(attempts) and is_list(errors) ->
        stream_error(reason)

      {:error, reason} ->
        stream_error(reason)
    end
  end

  defp stream_request_outcome({:ok, final_message}) do
    {:ok,
     Request.stop_metadata(
       Map.get(final_message, :id),
       Map.get(final_message, :stop_reason),
       Map.get(final_message, :usage)
     )}
  end

  defp stream_request_outcome({:error, %LLMError{} = error}), do: {:error, error}

  defp track_delivery(callback, delivered) when is_function(callback, 2) do
    fn event, data ->
      :atomics.put(delivered, 1, 1)
      callback.(event, data)
    end
  end

  defp track_delivery(callback, _delivered), do: callback

  defp stream_error(%LLMError{} = error), do: {:error, error}
  defp stream_error(reason), do: raise_llm_call_error(reason)

  # One stream from the LLM. A client that can't stream answers
  # {:error, %LLMError{type: :unsupported}} (Normandy.LLM.Call).
  defp stream_attempt(config, request, callback) do
    case Call.stream(config.client, request, []) do
      {:ok, stream} ->
        # Normandy, not the adapter, delivers events to the caller's callback, in
        # stream order, as the stream is consumed.
        stream = Stream.each(stream, &deliver_stream_event(&1, callback))

        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        case config do
          %BaseAgentConfig{
            output_guardrails: [_ | _],
            output_guardrails_streaming_mode: :incremental
          } ->
            consume_stream_with_incremental_guards(stream, config, callback)

          _ ->
            events = Enum.to_list(stream)

            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case StreamProcessor.stream_error(events) do
              nil -> {:ok, StreamProcessor.build_final_message(events)}
              %LLMError{} = error -> {:error, stream_error_with_usage(error, events)}
            end
        end

      {:error, %LLMError{}} = error ->
        error
    end
  end

  # The events the stream callback receives, from the adapter-neutral stream events
  # (Normandy.Agents.Model, "Stream events"). Everything else is not delivered.
  defp deliver_stream_event(
         %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}},
         callback
       ),
       do: callback.(:text_delta, text)

  defp deliver_stream_event(
         %{type: "content_block_delta", delta: %{"type" => "thinking_delta", "thinking" => text}},
         callback
       ),
       do: callback.(:thinking_delta, text)

  defp deliver_stream_event(
         %{type: "content_block_start", content_block: %{"type" => "tool_use"} = tool},
         callback
       ),
       do: callback.(:tool_use_start, tool)

  defp deliver_stream_event(%{type: "message_start", message: message}, callback),
    do: callback.(:message_start, message)

  defp deliver_stream_event(%{type: "message_stop"}, callback), do: callback.(:message_stop, %{})
  defp deliver_stream_event(_event, _callback), do: :ok

  # Consumes a stream event-by-event, running output guards every
  # `output_guardrails_chunk_size` bytes of accumulated text. On violation,
  # halts consumption, emits telemetry + the :guardrail_violation callback
  # event, strips any partial tool-use block from the response, and returns
  # `{:ok, final_message_with_violations}`. A stream that failed (error event,
  # {:error, _} item, no message_stop) without a guardrail halt returns
  # `{:error, %LLMError{}}`; a guardrail halt is a deliberate stop, not a failure.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp consume_stream_with_incremental_guards(stream, config, callback) do
    guards = config.output_guardrails
    chunk_size = config.output_guardrails_chunk_size

    initial = %{events: [], accumulated: "", since_last_check: 0, violations: [], halted?: false}

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
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case Normandy.Guardrails.run(guards, new_accumulated) do
            {:ok, _} ->
              {:cont, %{base_acc | since_last_check: 0}}

            {:error, violations} ->
              report_incremental_violation(config, guards, violations, callback)
              {:halt, %{base_acc | violations: violations, halted?: true}}
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

    # A guardrail halt is a deliberate stop (no message_stop); anything else
    # that failed is an error even if the tail check also found a violation.
    stream_error = if final_acc.halted?, do: nil, else: StreamProcessor.stream_error(events)

    case stream_error do
      %LLMError{} = error ->
        {:error, stream_error_with_usage(error, events)}

      nil ->
        build_incremental_final_message(events, final_acc)
    end
  end

  # The events received before a stream failed still bill: attach their usage
  # (message_start input/cache counts, message_delta output) to the error.
  defp stream_error_with_usage(%LLMError{} = error, events) do
    usage =
      events
      |> Enum.filter(&match?(%{type: type} when type in ["message_start", "message_delta"], &1))
      |> StreamProcessor.build_final_message()
      |> Map.get(:usage)

    LLMError.with_usage(error, if(usage == %{}, do: nil, else: usage))
  end

  defp build_incremental_final_message(events, final_acc) do
    final_message = StreamProcessor.build_final_message(events)

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

  # Admission initialises the turn inside the run span, so the id is only known at
  # stop; the run result carries the config whose memory holds it.
  defp put_turn_id(stop_metadata, {%BaseAgentConfig{} = config, _response}) do
    case Metadata.turn_id(config) do
      nil -> stop_metadata
      turn_id -> Map.put_new(stop_metadata, :turn_id, turn_id)
    end
  end

  defp put_turn_id(stop_metadata, _result), do: stop_metadata

  # on_turn_end runs after the run span closes, on both outcomes, so its time is not
  # the run's and its hook span is not the run's child; a raised run's exception is
  # re-raised unchanged after the hook (the Runner never raises for on_turn_end).
  defp with_agent_run_span(config, telemetry_metadata, fun) do
    Span.span([:normandy, :agent, :run], telemetry_metadata, fn ->
      log_lifecycle(:info, "normandy agent run start",
        agent: log_agent_name(config),
        iteration: 0,
        max_iterations: max_run_iterations(config)
      )

      started_at = System.monotonic_time()

      try do
        {result, stop_metadata} = fun.()
        stop_metadata = put_turn_id(stop_metadata, result)
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
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      BaseAgentGlue.turn_end_raised(config, kind, reason, stacktrace)
      :erlang.raise(kind, reason, stacktrace)
  else
    result ->
      BaseAgentGlue.turn_end_ok(config, result)
      result
  end

  defp with_llm_call_span(config, telemetry_metadata, fun) do
    Span.span([:normandy, :agent, :llm_call], telemetry_metadata, fn ->
      log_lifecycle(:info, "normandy llm call start",
        agent: log_agent_name(config),
        model: config.model,
        iteration: telemetry_metadata.iteration
      )

      started_at = System.monotonic_time()

      try do
        {result, stop_metadata} = fun.()
        duration_ms = elapsed_ms(started_at)
        stop_metadata = merge_normalized_usage(stop_metadata, result)
        input_tokens = Map.get(stop_metadata, :input_tokens)
        output_tokens = Map.get(stop_metadata, :output_tokens)

        log_metadata = [
          agent: log_agent_name(config),
          model: config.model,
          iteration: telemetry_metadata.iteration,
          duration_ms: duration_ms,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          has_tool_calls: Map.get(stop_metadata, :has_tool_calls, false)
        ]

        log_metadata =
          case Map.fetch(stop_metadata, :served_by) do
            {:ok, served_by} -> log_metadata ++ [served_by: served_by]
            :error -> log_metadata
          end

        log_lifecycle(:info, "normandy llm call stop", log_metadata)
        log_dropped_thinking(Map.get(stop_metadata, :input_transformations, []), log_metadata)

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
    Span.span([:normandy, :tool, :execute], telemetry_metadata, fn ->
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

  # The chokepoint pipeline BaseAgent uses: the agent's selected behaviours
  # (default bundle = allow-all policy, no-op budget, no hooks) adapted into a
  # %Dispatch.Pipeline{}, plus a telemetry-instrumented execute_fn so tool spans
  # keep nesting under the agent.run span. With the default (nil) bundle this is
  # byte-identical to the pre-Phase-2 default_pipeline/0 + span_execute path.
  @doc false
  def base_agent_pipeline(config) do
    %{
      Config.to_pipeline(config.behaviours)
      | execute_fn: &span_execute/4
    }
  end

  # The stop metadata adds :status and, for a failed execution, :error_type (why
  # it failed, see Executor.error_type/0). The model sees the same {:error, msg}.
  defp span_execute(config, prepared_tool, tool_name, %ToolCall{} = call) do
    tool_meta = Metadata.tool(config, call, prepared_tool)

    with_tool_execute_span(config, tool_name, tool_meta, fn ->
      {r, error_type} =
        Executor.execute_tool_classified(prepared_tool, context: Context.build(config, call))

      stop_meta =
        case error_type do
          nil -> Map.put(tool_meta, :status, elem(r, 0))
          type -> Map.merge(tool_meta, %{status: elem(r, 0), error_type: type})
        end

      {r, stop_meta}
    end)
  end

  defp execute_one_tool_call(config, tool_call) do
    Dispatch.dispatch_one(config, tool_call, base_agent_pipeline(config))
  end

  # Streaming-loop variant: tool_call is a string-keyed map (raw LLM JSON).
  # Dispatch.dispatch_one/3 normalizes it into a %ToolCall{} before running the
  # same chokepoint pipeline as the non-streaming path.
  defp execute_one_streaming_tool_call(config, tool_call) do
    Dispatch.dispatch_one(config, tool_call, base_agent_pipeline(config))
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

  # The API dropped a replayed thinking block because its history changed since it
  # was produced (client.options :thinking_block_binding is :drop_block). The turn
  # goes on without that reasoning; a steady stream of these means something
  # rewrites the conversation (often a context provider changing the system prompt).
  defp log_dropped_thinking(transformations, log_metadata) do
    for %{"type" => "thinking_dropped"} = t <- transformations do
      log_lifecycle(
        :warning,
        "normandy thinking block dropped by the API at #{t["path"]} (#{t["reason"]})",
        Keyword.take(log_metadata, [:agent, :model])
      )
    end

    :ok
  end

  defp log_lifecycle(level, message, metadata) do
    Logger.log(level, message, metadata)
  end

  defp elapsed_ms(started_at) do
    (System.monotonic_time() - started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  # Adds the raw usage (only when the provider reported some) to llm_call stop
  # metadata; normalized counts are added later by merge_normalized_usage/2.
  defp put_usage(metadata, usage) when is_map(usage) and map_size(usage) > 0,
    do: Map.put(metadata, :usage, usage)

  defp put_usage(metadata, _usage), do: metadata

  # Normalized token counts (Normandy.Telemetry.Usage) beside the raw `usage`,
  # from the stop metadata's usage or, failing that, the result itself (a usage
  # map or a response carrying one). Absent counts stay absent.
  defp merge_normalized_usage(stop_metadata, result) do
    usage =
      case Map.get(stop_metadata, :usage) do
        nil -> usage_of(result)
        usage -> usage
      end

    Map.merge(stop_metadata, Usage.normalize(usage))
  end

  defp usage_of(%{} = result) do
    if Usage.normalize(result) == %{},
      do: Map.get(result, :usage) || Map.get(result, "usage"),
      else: result
  end

  @spec raise_llm_call_error(term()) :: no_return()
  defp raise_llm_call_error(%LLMError{} = error), do: raise(error)

  defp raise_llm_call_error(:open),
    do:
      raise(
        LLMError.new(type: :circuit_open, retryable?: false, detail: "circuit breaker is open")
      )

  defp raise_llm_call_error({:exception, error, stacktrace}) do
    if Kernel.is_exception(error) do
      reraise(error, stacktrace)
    else
      raise LLMError.wrap({:exception, error})
    end
  end

  # CircuitBreaker's rescue carries no stacktrace; the exception keeps its type.
  defp raise_llm_call_error({:exception, error}) do
    if Kernel.is_exception(error) do
      raise error
    else
      raise LLMError.wrap({:exception, error})
    end
  end

  defp raise_llm_call_error(reason), do: raise(LLMError.wrap(reason))

  defp pending_tool_call_count(%BaseAgentConfig{memory: memory}) do
    case AgentMemory.latest_message(memory) do
      %Message{role: "assistant", content: content} ->
        content |> Map.get(:tool_calls, []) |> length()

      _ ->
        0
    end
  end

  defp completed_iterations({%BaseAgentConfig{memory: memory}, _response}) do
    messages = AgentMemory.messages(memory)

    # messages/1 is chronological (oldest-first); re-reverse to scan newest-first
    # so Enum.find_value returns the *most recent* assistant turn_id.
    assistant_turn_id =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Message{role: "assistant", turn_id: turn_id} -> turn_id
        _ -> nil
      end)

    Enum.count(messages, fn
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
        %BaseAgentConfig{prompt_specification: prompt_specification} = config,
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
        %BaseAgentConfig{prompt_specification: prompt_specification} = config,
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
  - `:ordered` - Return `[{:ok, response} | {:error, error}]` in input order
    (default: true); with `false`, a stats map
  - `:timeout` - Timeout per item in milliseconds (default: 300_000ms); a
    timed-out item fails with `{:exit, :timeout}`
  - `:on_progress` - Called after each completion with `(completed, total)`
  - `:on_error` - Called for each failed item with `(input, error)`

  ## Examples

      # Simple batch
      inputs = [
        %{chat_message: "Hello"},
        %{chat_message: "How are you?"}
      ]
      {:ok, [{:ok, first}, {:ok, second}]} = BaseAgent.process_batch(agent, inputs)

      # With options
      {:ok, results} = BaseAgent.process_batch(
        agent,
        inputs,
        max_concurrency: 5
      )

  """
  @spec process_batch(BaseAgentConfig.t(), [term()], keyword()) ::
          {:ok, [Processor.item_result()] | Processor.batch_result()}
  def process_batch(agent, inputs, opts \\ []) do
    Processor.process_batch(agent, inputs, opts)
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
          {:ok, Processor.batch_result()}
  def process_batch_with_stats(agent, inputs, opts \\ []) do
    Processor.process_batch_with_stats(agent, inputs, opts)
  end

  # Runs input guardrails and raises Normandy.Guardrails.ViolationError on any
  # violation. Mirrors the input-side raise behaviour of ValidationMiddleware —
  # a rejected input is a hard halt, not a soft pass-through. Delegates to
  # admit/2 so the bang and non-bang entries share guard execution + telemetry;
  # the only difference is that a block here raises rather than returns.
  defp run_input_guardrails!(%BaseAgentConfig{} = config, value) do
    case admit(config, value) do
      :ok ->
        :ok

      {:block, violations} ->
        raise Normandy.Guardrails.ViolationError,
          message: "Agent input guardrail violation",
          violations: violations
    end
  end

  # Runs output guardrails before the answer is appended to memory. A violation
  # raises (output_guardrails_on_violation: :block, the default), so the answer
  # is neither returned nor saved; with :warn it is logged and the turn goes on.
  # Telemetry is emitted either way.
  defp run_output_guardrails(%BaseAgentConfig{output_guardrails: []}, _value), do: :ok

  defp run_output_guardrails(%BaseAgentConfig{output_guardrails: guards} = config, value) do
    case Normandy.Guardrails.run(guards, value) do
      {:ok, _value} ->
        :ok

      {:error, violations} ->
        emit_guardrail_violation(:output, config, guards, violations)
        output_violation(config.output_guardrails_on_violation, violations)
    end
  end

  defp output_violation(:block, violations) do
    raise Normandy.Guardrails.ViolationError,
      message: "Agent output guardrail violation",
      violations: violations
  end

  defp output_violation(:warn, violations) do
    IO.warn(
      "Agent output guardrail violation: " <> ValidationMiddleware.error_message(violations)
    )

    :ok
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

  # Emits the admission-decision event. Separate from :violation so consumers
  # can monitor admit/block/error rates on a single stream regardless of
  # outcome. Only emitted from admit/2,3 (and the in-turn path that delegates to
  # it), and only when guardrails are configured.
  defp emit_guardrail_decision(outcome, config, guards, violations) do
    :telemetry.execute(
      [:normandy, :agent, :guardrail, :decision],
      %{count: length(violations)},
      %{
        stage: :input,
        outcome: outcome,
        agent_name: config.name,
        guards: Enum.map(guards, &guard_module/1),
        violations: violations
      }
    )
  end

  # A block whose violation came from a crashed guard (on_error: :closed) is an
  # :error outcome; an ordinary policy rejection is a :block. run/3 short-circuits
  # on the first failing guard, so violations originate from a single guard.
  defp decision_outcome(violations) do
    if Enum.any?(violations, &(Map.get(&1, :constraint) == :guard_error)) do
      :error
    else
      :block
    end
  end

  defp guard_module(mod) when is_atom(mod), do: mod
  defp guard_module({mod, _opts}), do: mod

  # Runs output guardrails on the accumulated text of a streaming final message.
  # Dispatches by mode: :accumulate runs guards after the stream completes
  # (logged and reported, not blocked: the text already reached the caller); :incremental is a
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
            ValidationMiddleware.error_message(violations)
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
