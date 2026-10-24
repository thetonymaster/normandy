defmodule Normandy.Agents.BaseAgent do
  @moduledoc """
  Core agent implementation providing conversational AI capabilities.

  BaseAgent manages agent state, memory, and LLM interactions through a
  stateful configuration approach.

  `run/3` returns `{:ok, config, output}` or `{:error, exception}` for Normandy's own
  failures (listed on `run/3`) and raises for bugs; `run!/3` returns
  `{config, output}` and raises either way.
  """

  alias Normandy.Agents.BaseAgent.Handlers
  alias Normandy.Agents.BaseAgent.InitOptions
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Batch.Processor
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.StreamEvent
  alias Normandy.Options
  alias Normandy.Tools.Toolset
  alias Normandy.TurnError

  @doc """
  Builds an agent config from `opts`, a keyword list or a map.

  Every option is checked before anything starts: an unknown option, a missing `:client`
  or `:model`, or a bad value raises `ArgumentError` naming the option (and, for an
  unknown one, the supported options). Values of credential-carrying options such as
  `:client` are never shown in the message.

      agent = BaseAgent.init(client: client, model: "claude-opus-5-5")

  ## Options

  #{Normandy.Options.docs(InitOptions.schema())}
  """
  @spec init(keyword() | map()) :: BaseAgentConfig.t()
  def init(opts) do
    opts = InitOptions.check_init!(opts)
    client = Keyword.fetch!(opts, :client)
    behaviours = Keyword.fetch!(opts, :behaviours)
    :ok = InitOptions.warn_deprecated_catalog(behaviours)

    memory = Keyword.fetch!(opts, :memory) || AgentMemory.new_memory()

    %BaseAgentConfig{
      input_schema: Keyword.fetch!(opts, :input_schema) || %BaseAgentInputSchema{},
      output_schema: Keyword.fetch!(opts, :output_schema) || %BaseAgentOutputSchema{},
      memory: memory,
      initial_memory: memory,
      prompt_specification: Keyword.fetch!(opts, :prompt_specification) || %PromptSpecification{},
      client: client,
      model: Keyword.fetch!(opts, :model),
      current_user_input: nil,
      temperature: Keyword.fetch!(opts, :temperature),
      max_tokens: Keyword.fetch!(opts, :max_tokens),
      toolset: Keyword.fetch!(opts, :toolset),
      max_tool_iterations: Keyword.fetch!(opts, :max_tool_iterations),
      max_tool_concurrency: Keyword.fetch!(opts, :max_tool_concurrency),
      max_tool_result_chars: Keyword.fetch!(opts, :max_tool_result_chars),
      retry: Keyword.fetch!(opts, :retry),
      circuit_breaker: Keyword.fetch!(opts, :circuit_breaker),
      enable_json_retry: Keyword.fetch!(opts, :enable_json_retry),
      json_retry_max_attempts: Keyword.fetch!(opts, :json_retry_max_attempts),
      mcp_servers: Keyword.fetch!(opts, :mcp_servers),
      name: Keyword.fetch!(opts, :name),
      session_id: Keyword.fetch!(opts, :session_id),
      tool_context: Keyword.fetch!(opts, :tool_context),
      guardrails: Keyword.fetch!(opts, :guardrails),
      behaviours: behaviours
    }
  end

  @doc """
  Returns `config` with its memory back to the memory it was built with (`init/1`'s
  `:memory`, empty by default), dropping every turn since. Nothing else changes: tools,
  context providers and the prompt specification stay as they are.
  """
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

  def admit(%BaseAgentConfig{} = config, value, context) do
    case BaseAgentConfig.guardrail(config, :input) do
      [] -> :ok
      guards -> Handlers.admit_with(config, guards, value, context)
    end
  end

  @doc """
  Makes one LLM request with the agent's prompt, tools and memory, outside any run, and
  returns the response parsed into `response_model` (default: the output schema). It is
  an `[:normandy, :agent, :llm_call]` span with no `iteration` and no run around it.
  """
  @spec get_response(BaseAgentConfig.t(), struct() | nil) :: struct()
  def get_response(%BaseAgentConfig{} = config, response_model \\ nil),
    do: Handlers.get_response(config, response_model)

  @doc """
  Runs one turn: validates `user_input` against the input schema, calls the model (and
  the tools it asks for, when the agent has tools) and returns the answer converted to
  the output schema.

  Returns `{:ok, config, output}`, where `config` holds the turn in its memory, or
  `{:error, exception}` when Normandy's own checks or the model failed:
  `Normandy.LLMError`, `Normandy.Schema.ValidationError`,
  `Normandy.Guardrails.ViolationError`, `Normandy.HookHaltError`,
  `Normandy.ModelCatalogError` or `Normandy.TurnError`. An answer cut off at `max_tokens` (or the context window) or refused is `{:error, %Normandy.LLMError{type: :max_tokens}}` or `type: :refusal`, and no tool call from it runs. A blank final answer is `{:error, %Normandy.LLMError{type: :invalid_output}}`, except for a chat (`:chat_message`) agent whose last tool-calling response in this turn carried text: that text is the answer, and the run `:stop` telemetry says so with `answer_source: :tool_round` (`:final` otherwise); memory stores the sentence twice (in that response and as the answer), and later requests show it once (as they do when the model itself repeated it), unless that response or a later message of the turn carries thinking the request sends, or its text carries citations. Any other exception (a bug in a
  tool, a hook under `on_error: :reraise`, a client) is raised. On `{:error, _}` the
  turn is lost: keep using the config you passed in.

  `user_input` may be `nil` to continue the conversation without a new user message.
  `run/3` takes no options yet: any option, or options that are not a keyword list, raise
  `ArgumentError` naming `run/3`. To stream, use `stream/3`.

  ## Example

      {:ok, agent, response} = BaseAgent.run(agent, %{chat_message: "Hello"})
  """
  @spec run(BaseAgentConfig.t(), term(), keyword()) ::
          {:ok, BaseAgentConfig.t(), term()} | {:error, Exception.t()}
  def run(config, user_input \\ nil, opts \\ []) do
    :ok = check_run_opts!(opts, :run)
    {config, output} = run!(config, user_input, opts)
    {:ok, config, output}
  rescue
    e -> domain_error(e, __STACKTRACE__)
  end

  @doc """
  Like `run/3`, but returns `{config, output}` and raises the exception `run/3` would
  return.
  """
  @spec run!(BaseAgentConfig.t(), term(), keyword()) :: {BaseAgentConfig.t(), term()}
  def run!(%BaseAgentConfig{} = config, user_input \\ nil, opts \\ []) do
    :ok = check_run_opts!(opts, :run!)
    Handlers.run(config, user_input)
  end

  # run/3 and run!/3 take no options yet; if one gains options it gets a
  # Normandy.Options schema instead of this check.
  defp check_run_opts!([], _fun), do: :ok

  defp check_run_opts!(opts, fun) when is_list(opts) do
    prefix = "Normandy.Agents.BaseAgent.#{fun}/3"

    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{prefix}: expected options as a keyword list, got a list that is not one; " <>
              "#{fun}/3 takes no options"
    end

    keys = Keyword.keys(opts)

    hint =
      if Enum.any?(keys, &(&1 in [:stream, :on_chunk])),
        do: ". Streaming moved to BaseAgent.stream/3",
        else: ""

    names =
      case keys do
        [key] -> "option #{inspect(key)}"
        keys -> "options #{inspect(keys)}"
      end

    raise ArgumentError, "#{prefix}: unknown #{names}; #{fun}/3 takes no options#{hint}"
  end

  defp check_run_opts!(other, fun) do
    raise ArgumentError,
          "Normandy.Agents.BaseAgent.#{fun}/3: expected options as a keyword list, got " <>
            "#{Describe.type_of(other)}; #{fun}/3 takes no options"
  end

  @doc """
  Runs one turn like `run/3`, streaming the model's output to `callback` as it arrives.

  `callback` receives a `Normandy.Components.StreamEvent` per event (text and thinking
  deltas, tool calls and results, guardrail reports). The return value is `run/3`'s:
  `{:ok, config, output}` with the answer converted to the output schema, or
  `{:error, exception}`. A client that can't stream gives
  `{:error, %Normandy.LLMError{type: :unsupported}}`.

  The streamed text is parsed into a non-chat output schema once, under the client's
  `:on_parse_failure` policy: `enable_json_retry` does not apply, so text that does not
  parse is not re-asked. The same holds for `run/3`'s final answer after a tool loop; a
  `run/3` without tools re-asks through the adapter.

  `retry` and the circuit breaker apply, but a stream is retried only until its
  first event reaches the callback, so no output is shown twice. Output guardrails
  report (`:guardrail_violation` event, telemetry) and don't block: the text was already
  delivered; with `guardrails: [streaming_mode: :incremental]` a violation stops
  the stream at the next chunk boundary.

  A stream that stops at `max_tokens`, the context window or a refusal returns
  `{:error, %Normandy.LLMError{type: :max_tokens | :refusal}}`, as `run/3` does: the
  deltas already delivered to `callback` stay delivered, and nothing of that response is
  stored or run.

  ## Example

      {:ok, agent, response} =
        BaseAgent.stream(agent, "Explain OTP", fn
          %StreamEvent{type: :text_delta, data: text} -> IO.write(text)
          _event -> :ok
        end)
  """
  @spec stream(BaseAgentConfig.t(), term(), (StreamEvent.t() -> any())) ::
          {:ok, BaseAgentConfig.t(), term()} | {:error, Exception.t()}
  def stream(%BaseAgentConfig{} = config, user_input, callback) when is_function(callback, 1) do
    {config, output} = Handlers.stream(config, user_input, callback)
    {:ok, config, output}
  rescue
    e -> domain_error(e, __STACKTRACE__)
  end

  # run/3 and stream/3 return Normandy's own failures (TurnError.domain?/1) and raise
  # everything else unchanged.
  defp domain_error(exception, stacktrace) do
    if TurnError.domain?(exception),
      do: {:error, exception},
      else: reraise(exception, stacktrace)
  end

  @doc """
  Looks up the context provider registered under `name`: `{:ok, provider}` or `:error`.
  """
  @spec fetch_context_provider(BaseAgentConfig.t(), atom()) :: {:ok, struct()} | :error
  def fetch_context_provider(
        %BaseAgentConfig{prompt_specification: %{context_providers: providers}},
        name
      ),
      do: Map.fetch(providers, name)

  @doc """
  Like `fetch_context_provider/2`, but returns the provider or raises
  `Normandy.ContextProviderNotFoundError`.
  """
  @spec fetch_context_provider!(BaseAgentConfig.t(), atom()) :: struct()
  def fetch_context_provider!(
        %BaseAgentConfig{prompt_specification: %{context_providers: providers}},
        name
      ) do
    case Map.fetch(providers, name) do
      {:ok, provider} ->
        provider

      :error ->
        raise Normandy.ContextProviderNotFoundError,
          name: name,
          registered: providers |> Map.keys() |> Enum.sort()
    end
  end

  @doc """
  Returns `config` with `provider` registered under `name`, replacing any provider already
  registered under that name. `provider` is a struct implementing
  `Normandy.Components.ContextProvider`; its `title/1` and `get_info/1` are read each time
  the system prompt is built, into the prompt's "Context" section.
  """
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

  @doc """
  Returns `config` without the context provider registered under `name`. Deleting a name
  with no provider returns `config` unchanged.
  """
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
  Registers `tool` in the agent's toolset, creating the toolset on first use. `opts` are
  `Normandy.Tools.Toolset.register/3`'s options.
  """
  @spec register_tool(BaseAgentConfig.t(), struct(), keyword()) :: BaseAgentConfig.t()
  def register_tool(config, tool, opts \\ [])

  def register_tool(%BaseAgentConfig{toolset: nil} = config, tool, opts),
    do: register_tool(%{config | toolset: Toolset.new()}, tool, opts)

  def register_tool(%BaseAgentConfig{toolset: %Toolset{} = toolset} = config, tool, opts),
    do: %{config | toolset: Toolset.register(toolset, tool, opts)}

  @doc """
  Looks up a registered tool by name: `{:ok, tool}` or `:error` (also when no tool is
  registered).
  """
  @spec fetch_tool(BaseAgentConfig.t(), String.t()) :: {:ok, struct()} | :error
  def fetch_tool(%BaseAgentConfig{} = config, tool_name),
    do: Toolset.fetch(toolset_of(config), tool_name)

  @doc """
  Like `fetch_tool/2`, but returns the tool or raises `Normandy.ToolNotFoundError`.
  """
  @spec fetch_tool!(BaseAgentConfig.t(), String.t()) :: struct()
  def fetch_tool!(%BaseAgentConfig{} = config, tool_name),
    do: Toolset.fetch!(toolset_of(config), tool_name)

  # No toolset yet is an empty one: the lookups answer the same way.
  defp toolset_of(%BaseAgentConfig{toolset: nil}), do: Toolset.new([])

  defp toolset_of(%BaseAgentConfig{toolset: toolset}), do: toolset

  @doc """
  Lists all tools available to the agent.

  ## Examples

      BaseAgent.list_tools(agent)
      #=> [%Calculator{}, %StringManipulator{}]

  """
  @spec list_tools(BaseAgentConfig.t()) :: [struct()]
  def list_tools(%BaseAgentConfig{toolset: nil}), do: []

  def list_tools(%BaseAgentConfig{toolset: registry}) do
    Toolset.list(registry)
  end

  @doc """
  Checks if the agent has any tools registered.

  ## Examples

      BaseAgent.has_tools?(agent)
      #=> true

  """
  @spec has_tools?(BaseAgentConfig.t()) :: boolean()
  def has_tools?(%BaseAgentConfig{toolset: nil}), do: false

  def has_tools?(%BaseAgentConfig{toolset: registry}), do: Toolset.count(registry) > 0

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
  Discovers and registers client-side MCP tools in the agent's toolset.

  Connects to an MCP server via the specified adapter, discovers available tools,
  and registers them as Normandy tools that can be used in the agent's tool loop.

  ## Options

  The options of `Normandy.MCP.Registry.discover_and_register/4`.

  ## Examples

      agent = BaseAgent.register_mcp_tools(agent, MyAdapter, mcp_client, prefix: "server1")

  """
  @spec register_mcp_tools(BaseAgentConfig.t(), module(), term(), keyword()) ::
          {:ok, BaseAgentConfig.t()} | {:error, term()}
  def register_mcp_tools(%BaseAgentConfig{} = config, adapter, client, opts \\ []) do
    opts =
      Options.validate!(
        opts,
        Normandy.MCP.Registry.__opts_schema__(:discover_and_register),
        {__MODULE__, :register_mcp_tools, 4}
      )

    registry = config.toolset || Toolset.new()

    case Normandy.MCP.Registry.discover_and_register(registry, adapter, client, opts) do
      {:ok, updated_registry} ->
        {:ok, %{config | toolset: updated_registry}}

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

  The options of `Normandy.Batch.Processor.process_batch/3`.

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
    opts =
      Options.validate!(
        opts,
        Processor.__opts_schema__(:process_batch),
        {__MODULE__, :process_batch, 3}
      )

    Processor.process_batch(agent, inputs, opts)
  end

  @doc """
  Process a batch and return detailed statistics.

  Returns success/error breakdown with counts.

  ## Options

  The options of `Normandy.Batch.Processor.process_batch_with_stats/3`.

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
    opts =
      Options.validate!(
        opts,
        Processor.__opts_schema__(:process_batch_with_stats),
        {__MODULE__, :process_batch_with_stats, 3}
      )

    Processor.process_batch_with_stats(agent, inputs, opts)
  end
end
