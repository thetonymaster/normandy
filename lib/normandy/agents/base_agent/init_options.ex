defmodule Normandy.Agents.BaseAgent.InitOptions do
  @moduledoc false
  # The `BaseAgent.init/1` option schema, its custom checks, hints for option names a
  # caller might reasonably try, and the config checks init/1 makes after the schema
  # (check_init!/1; ConfigTemplate.rebuild/3 and AgentPool reuse them).
  # `Normandy.DSL.Agent`'s generated `new/1` uses the same definition (without
  # defaults), so both entry points accept the same options.

  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Model
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.Hooks
  alias Normandy.Behaviours.ModelCatalog
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLM.OpenAICompatibleAdapter
  alias Normandy.Options
  alias Normandy.Resilience.Retry
  alias Normandy.Tools.Toolset

  @guard_spec {:or, [:atom, {:tuple, [:atom, :keyword_list]}]}

  @definition [
    client: [
      type: {:custom, __MODULE__, :client, []},
      required: true,
      type_doc: "a struct implementing `Normandy.Agents.Model`",
      doc: "The LLM client, for example a `Normandy.LLM.ClaudioAdapter`."
    ],
    model: [type: :string, required: true, doc: "The model id sent with every request."],
    temperature: [
      type: {:or, [:float, :integer, nil]},
      default: nil,
      type_doc: "`t:number/0` or `nil`",
      doc: "Sampling temperature. `nil` leaves it out of the request (Opus 4.7+ reject it)."
    ],
    max_tokens: [
      type: {:custom, __MODULE__, :max_tokens, []},
      default: BaseAgentConfig.default_max_tokens(),
      type_doc: "`t:pos_integer/0`",
      doc: "The answer's token limit; the Messages API requires one."
    ],
    input_schema: [
      type: {:custom, __MODULE__, :struct_or_nil, []},
      default: nil,
      type_doc: "an `io_schema` struct or `nil`",
      doc: "The input schema; `nil` is `Normandy.Agents.BaseAgentInputSchema`."
    ],
    output_schema: [
      type: {:custom, __MODULE__, :struct_or_nil, []},
      default: nil,
      type_doc: "an `io_schema` struct or `nil`",
      doc: "The output schema; `nil` is `Normandy.Agents.BaseAgentOutputSchema`."
    ],
    memory: [
      type: {:or, [{:struct, Normandy.Components.AgentMemory}, nil]},
      default: nil,
      type_doc: "a `Normandy.Components.AgentMemory` or `nil`",
      doc: "The starting memory, also what `reset_memory/1` restores; `nil` is empty."
    ],
    prompt_specification: [
      type: {:or, [{:struct, Normandy.Components.PromptSpecification}, nil]},
      default: nil,
      type_doc: "a `Normandy.Components.PromptSpecification` or `nil`",
      doc: "The system prompt's sections; `nil` is an empty specification."
    ],
    toolset: [
      type: {:or, [{:struct, Normandy.Tools.Toolset}, nil]},
      default: nil,
      type_doc: "a `Normandy.Tools.Toolset` or `nil`",
      doc: "The agent's tools."
    ],
    max_tool_iterations: [
      type: :pos_integer,
      default: 20,
      doc:
        "Tool rounds per turn. After the last one the turn stores a notice and makes one more call with `tool_choice: :none`, whose answer is the turn's output."
    ],
    max_tool_concurrency: [
      type: {:custom, __MODULE__, :max_tool_concurrency, []},
      default: 1,
      type_doc: "`t:integer/0`",
      doc: "Tool calls run at once; a value below 1 counts as 1."
    ],
    max_tool_result_chars: [
      type: {:or, [:pos_integer, nil]},
      default: BaseAgentConfig.default_max_tool_result_chars(),
      type_doc: "`t:pos_integer/0` or `nil`",
      doc:
        "The longest tool result, in characters (graphemes), the model sees; a longer one " <>
          "is cut and ends with a note saying how much was shown. `nil` = no cap. A tool's " <>
          "`Normandy.Tools.Toolset.register/3` `:max_result_chars` overrides it."
    ],
    retry: [
      type: {:custom, __MODULE__, :retry, []},
      default: nil,
      type_doc: "`t:keyword/0` or `nil`",
      doc: "`Normandy.Resilience.Retry` options for LLM calls; `nil` makes one attempt."
    ],
    circuit_breaker: [
      type: {:custom, __MODULE__, :circuit_breaker, []},
      default: nil,
      type_doc: "`t:keyword/0` or `nil`",
      doc:
        "Options of the shared `Normandy.Resilience.CircuitBreaker` this agent's LLM calls " <>
          "go through: `:failure_threshold` (failures before it opens), `:success_threshold` " <>
          "(successes that close it from half-open), `:timeout` (milliseconds open before " <>
          "half-open), `:half_open_max_calls` (calls let through when half-open), `:scope` " <>
          "(any plain term; agents with a different scope get different breakers). Agents with " <>
          "the same client module, endpoint, model and options share one breaker, started on " <>
          "the first call under Normandy's supervisor. `[]` uses the breaker's defaults; `nil` " <>
          "uses none. Only failures that say the endpoint is unhealthy count: `LLMError` " <>
          "types `:rate_limit`, `:overloaded`, `:server`, `:transport`, `:stream`, or any " <>
          "retryable error; a rejected request, unparseable output or a raise from your own " <>
          "code does not."
    ],
    enable_json_retry: [
      type: :boolean,
      default: true,
      doc:
        "Asks the model again when its JSON does not parse (`Normandy.LLM.ClaudioAdapter`; " <>
          "`Normandy.LLM.OpenAICompatibleAdapter` does not) or, on any client, when a direct " <>
          "answer breaks a schema constraint."
    ],
    json_retry_max_attempts: [
      type: :pos_integer,
      default: 2,
      doc:
        "Re-asks per call: for JSON that does not parse (none with " <>
          "`Normandy.LLM.OpenAICompatibleAdapter`), then for a broken constraint; a constraint " <>
          "re-ask makes no parse re-asks of its own."
    ],
    guardrails: [
      type: :keyword_list,
      default: [],
      keys: [
        input: [type: {:list, @guard_spec}, default: [], doc: "Guards for the input."],
        output: [type: {:list, @guard_spec}, default: [], doc: "Guards for the answer."],
        streaming_mode: [
          type: {:in, [:accumulate, :incremental]},
          default: :accumulate,
          doc: "When `stream/3` checks the output guards."
        ],
        chunk_size: [
          type: :pos_integer,
          default: 200,
          doc: "Bytes of streamed text between incremental checks."
        ],
        on_violation: [
          type: {:in, [:block, :warn]},
          default: :block,
          doc: "What an output violation does."
        ]
      ],
      doc: "`Normandy.Guardrails` guards and how they apply."
    ],
    name: [type: {:or, [:string, nil]}, default: nil, doc: "The agent's name."],
    session_id: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "The session id put on telemetry and tool contexts."
    ],
    behaviours: [
      type: {:or, [{:struct, Normandy.Behaviours.Config}, nil]},
      default: nil,
      type_doc: "a `Normandy.Behaviours.Config` or `nil`",
      doc: "Pluggable behaviours and hooks; `nil` is the default bundle."
    ],
    mcp_servers: [
      type: {:or, [{:list, :any}, nil]},
      default: nil,
      type_doc: "a list of MCP server configs or `nil`",
      doc: "MCP servers whose tools the agent may call."
    ],
    tool_context: [
      type: {:custom, Normandy.Options, :plain_map, []},
      default: %{},
      type_doc: "`t:map/0`",
      doc: "Plain data handed to tools; persisted in session templates, so no secrets."
    ]
  ]

  @schema NimbleOptions.new!(@definition)

  # Option names callers try that are not init/1 options, with where the setting lives.
  @hints [
    system_prompt:
      "the system prompt goes in :prompt_specification (a %Normandy.Components.PromptSpecification{})",
    tools:
      "tools go in :toolset (Normandy.Tools.Toolset.new([tool, ...])) or are added " <>
        "after init with BaseAgent.register_tool/3",
    max_messages:
      "cap the memory with memory: Normandy.Components.AgentMemory.new_memory(max_messages)"
  ]

  # 1.x init/1 options that 2.0 renamed or regrouped.
  @renamed [
    retry_options: "was renamed to :retry",
    enable_circuit_breaker:
      "was removed: circuit_breaker: [] (or the breaker's options) configures a breaker",
    circuit_breaker_options: "was renamed to :circuit_breaker",
    input_guardrails: "moved to guardrails: [input: ...]",
    output_guardrails: "moved to guardrails: [output: ...]",
    output_guardrails_streaming_mode: "moved to guardrails: [streaming_mode: ...]",
    output_guardrails_chunk_size: "moved to guardrails: [chunk_size: ...]",
    output_guardrails_on_violation: "moved to guardrails: [on_violation: ...]"
  ]

  @breaker_schema Normandy.Resilience.CircuitBreaker.__opts_schema__(:key).schema
                  |> Enum.map(fn {key, spec} -> {key, Keyword.delete(spec, :default)} end)
                  |> NimbleOptions.new!()

  # The caller init/1's errors name. A literal atom, not the alias: a reference to
  # BaseAgent here (a runtime edge) puts BaseAgent's compile-time read of this module's
  # schema in a compile-connected cycle with everything BaseAgent reaches.
  @init {:"Elixir.Normandy.Agents.BaseAgent", :init, 1}

  @doc false
  @spec definition() :: keyword()
  def definition, do: @definition

  @doc false
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @doc false
  # Checks `BaseAgent.init/1`'s options: misnamed keys, then unknown keys (so a misspelled
  # :model is named, decision 9), then :model, then the schema. With an unknown key,
  # Options.validate!/3 reports it: NimbleOptions checks unknown keys before required ones.
  @spec validate!(keyword() | map()) :: keyword()
  def validate!(opts) do
    :ok = check_misnamed!(opts, @schema, @init)

    if model_missing?(opts) and unknown_keys(opts, @schema) == [] do
      raise ArgumentError,
            "Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none"
    end

    Options.validate!(opts, @schema, @init)
  end

  @doc false
  # Raises for a 1.x key in @renamed, naming its 2.0 home, and for a key in @hints that
  # `schema` does not itself accept, naming where the setting lives and `schema`'s options.
  @spec check_misnamed!(term(), NimbleOptions.t(), {module(), atom(), arity()}) :: :ok
  def check_misnamed!(opts, %NimbleOptions{} = schema, {mod, fun, arity}) do
    keys = option_keys(opts)
    supported = Keyword.keys(schema.schema)
    prefix = "#{inspect(mod)}.#{fun}/#{arity}"

    case Enum.find(@renamed, fn {key, _change} -> key in keys end) do
      {key, change} ->
        raise ArgumentError,
              "#{prefix}: #{inspect(key)} #{change} in 2.0; see MIGRATING-2.0.md §22"

      nil ->
        :ok
    end

    case Enum.find(@hints, fn {key, _hint} -> key in keys and key not in supported end) do
      nil ->
        :ok

      {key, hint} ->
        raise ArgumentError,
              "#{prefix}: unknown option #{inspect(key)}; #{hint}; " <>
                "supported: #{Enum.map_join(supported, ", ", &inspect/1)}"
    end
  end

  @doc false
  # The definition with no defaults and nothing required, at every level: for an entry
  # point (DSL new/1) where an option left out keeps a value declared elsewhere.
  @spec without_defaults(keyword()) :: keyword()
  def without_defaults(definition) do
    Enum.map(definition, fn {key, spec} ->
      spec =
        spec
        |> Keyword.delete(:default)
        |> Keyword.put(:required, false)

      spec =
        if Keyword.has_key?(spec, :keys),
          do: Keyword.update!(spec, :keys, &without_defaults/1),
          else: spec

      {key, spec}
    end)
  end

  # Malformed options are Options.validate!/3's to report; here they just have no keys.
  defp option_keys(%_{}), do: []
  defp option_keys(opts) when is_map(opts), do: Map.keys(opts)
  defp option_keys(opts) when is_list(opts), do: for({key, _value} <- opts, do: key)
  defp option_keys(_opts), do: []

  defp unknown_keys(opts, %NimbleOptions{} = schema),
    do: option_keys(opts) -- Keyword.keys(schema.schema)

  defp model_missing?(%_{}), do: false

  defp model_missing?(opts) when is_map(opts),
    do: Enum.all?(Map.keys(opts), &is_atom/1) and Map.get(opts, :model) == nil

  defp model_missing?(opts) when is_list(opts),
    do: Keyword.keyword?(opts) and Keyword.get(opts, :model) == nil

  defp model_missing?(_opts), do: false

  @doc false
  # A struct whose module has no Normandy.Agents.Model implementation would fail mid-turn,
  # at the first LLM call; it is rejected here instead.
  def client(%mod{} = client) do
    if Model.impl_for(client),
      do: {:ok, client},
      else:
        {:error,
         "expected a client struct, got a %#{inspect(mod)}{}, which does not implement Normandy.Agents.Model"}
  end

  def client(other), do: {:error, "expected a client struct, got #{Describe.type_of(other)}"}

  @doc false
  def max_tokens(n) when is_integer(n) and n > 0, do: {:ok, n}

  def max_tokens(other) do
    {:error,
     "expected a positive integer (the Messages API requires it), got: #{inspect(other)}. " <>
       "Omit it to use the default of #{BaseAgentConfig.default_max_tokens()}."}
  end

  @doc false
  def struct_or_nil(nil), do: {:ok, nil}
  def struct_or_nil(%_{} = schema), do: {:ok, schema}

  def struct_or_nil(other),
    do: {:error, "expected a schema struct or nil, got #{Describe.type_of(other)}"}

  @doc false
  # The clamp is BaseAgent's (the DSL also calls it at compile time): one definition.
  def max_tool_concurrency(n) when is_integer(n),
    do: {:ok, normalize_max_tool_concurrency(n)}

  def max_tool_concurrency(other), do: {:error, "expected an integer, got: #{inspect(other)}"}

  @doc false
  # Retry checks its own options (Retry.validate_options!/1); its ArgumentError becomes
  # this option's error so the message carries init/1's prefix.
  def retry(nil), do: {:ok, nil}

  def retry(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      :ok = Retry.validate_options!(opts)
      {:ok, opts}
    else
      {:error, "expected a keyword list or nil, got a list that is not one"}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def retry(other),
    do: {:error, "expected a keyword list or nil, got #{Describe.type_of(other)}"}

  @doc false
  def circuit_breaker(nil), do: {:ok, nil}

  def circuit_breaker(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      validate_breaker(opts)
    else
      {:error, "expected a keyword list or nil, got a list that is not one"}
    end
  end

  def circuit_breaker(other),
    do: {:error, "expected a keyword list or nil, got #{Describe.type_of(other)}"}

  # Duplicated, then unknown keys in the house style ("unknown option :x; supported: ..."),
  # like Normandy.Options; any other error is NimbleOptions' message. Duplicates come first:
  # `keys -- schema_keys` removes one occurrence, so a duplicated known key would otherwise
  # read as unknown.
  defp validate_breaker(opts) do
    keys = Keyword.keys(opts)
    supported = Enum.map_join(Keyword.keys(@breaker_schema.schema), ", ", &inspect/1)

    with {:dups, []} <- {:dups, Enum.uniq(keys -- Enum.uniq(keys))},
         {:unknown, []} <- {:unknown, Enum.uniq(keys -- Keyword.keys(@breaker_schema.schema))},
         {:ok, validated} <- NimbleOptions.validate(opts, @breaker_schema) do
      {:ok, validated}
    else
      {:error, %NimbleOptions.ValidationError{value: value} = error} ->
        {:error, Options.redact_container(Exception.message(error), value)}

      {:dups, dups} ->
        {:error, "#{option_names(dups)} given more than once"}

      {:unknown, keys} ->
        {:error, "unknown #{option_names(keys)}; supported: #{supported}"}
    end
  end

  defp option_names([key]), do: "option #{inspect(key)}"
  defp option_names(keys), do: "options #{inspect(keys)}"

  @doc false
  # Every check init/1 makes, with no side effect (no process started): the options schema,
  # then the compaction, client-option, policy and hook checks. Returns the validated
  # options. AgentPool.start_link/1 calls it in its caller so a bad :agent_config raises
  # there, not inside the pool's init/1. Messages name init/1.
  @spec check_init!(keyword() | map()) :: keyword()
  def check_init!(opts) do
    opts = validate!(opts)
    client = Keyword.fetch!(opts, :client)
    behaviours = Keyword.fetch!(opts, :behaviours)

    _ =
      validate_compaction_config!(
        %BaseAgentConfig{client: client, behaviours: behaviours},
        @init
      )

    _ = validate_client_options!(client)
    :ok = validate_policy_opts!(behaviours)
    :ok = validate_hooks!(behaviours)
    opts
  end

  @doc false
  # init/1 and ConfigTemplate.rebuild/3: ModelCatalog.Static logs its deprecation once
  # per VM. Only the module is checked, never the catalog's opts.
  @spec warn_deprecated_catalog(Config.t() | nil) :: :ok
  def warn_deprecated_catalog(%Config{model_catalog: {ModelCatalog.Static, _opts}}),
    do: ModelCatalog.Static.warn_deprecated()

  def warn_deprecated_catalog(_behaviours), do: :ok

  # Coerce inbound `:max_tool_concurrency` into the `pos_integer()` shape the
  # struct's typespec promises (Dispatch.run_batch/3 reads it as is). Integers < 1
  # are clamped to 1. Non-integers raise — silently coercing `"4"` or
  # `4.0` to 1 hides a real config bug from the caller. Public so the DSL
  # `__before_compile__` quote can reuse it for compile-time validation.
  @doc false
  def normalize_max_tool_concurrency(n) when is_integer(n) and n >= 1, do: n

  def normalize_max_tool_concurrency(n) when is_integer(n) and n < 1, do: 1

  def normalize_max_tool_concurrency(other) do
    raise ArgumentError,
          ":max_tool_concurrency must be an integer >= 1, got: #{inspect(other)}"
  end

  @doc false
  # The compactor ref of a config; Compactor.NoOp when none is set.
  def compactor_ref(%BaseAgentConfig{behaviours: %Normandy.Behaviours.Config{compactor: ref}})
      when not is_nil(ref),
      do: ref

  def compactor_ref(_config), do: {Normandy.Behaviours.Compactor.NoOp, []}

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
  # Each registered tool checks the config's tool_context (Normandy.Tool.check_context!/2),
  # where a tool and a context first meet: init/1, register_tool/3 and
  # ConfigTemplate.rebuild/3.
  @spec check_tool_context!(BaseAgentConfig.t()) :: BaseAgentConfig.t()
  def check_tool_context!(%BaseAgentConfig{toolset: nil} = config), do: config

  def check_tool_context!(%BaseAgentConfig{toolset: toolset, tool_context: values} = config) do
    Enum.each(Toolset.list(toolset), &Normandy.Tool.check_context!(&1, values))
    config
  end

  @doc false
  # A real compactor sizes against the model's context window. With no pinned
  # :context_window and the default catalog (the Anthropic Models API), that lookup
  # needs a ClaudioAdapter client; any other client makes every compaction raise
  # mid-turn, after tools ran. Called from init/1 and ConfigTemplate.rebuild/3 so
  # the mistake surfaces where the config is made; `entry` is that public function's
  # {module, function, arity}, which prefixes every message. Never inspects the client
  # value (it may hold an API key), only its struct name, nor the compactor's opts.
  # Takes any %BaseAgentConfig{}: init/1 validates a partial one (client + behaviours only).
  @spec validate_compaction_config!(BaseAgentConfig.partial(), {module(), atom(), arity()}) ::
          BaseAgentConfig.partial()
  def validate_compaction_config!(%BaseAgentConfig{} = config, {mod, fun, arity} = entry) do
    prefix = "#{inspect(mod)}.#{fun}/#{arity}:"
    {compactor, compactor_opts} = compactor_ref(config)
    {catalog, _catalog_opts} = catalog_ref(config)

    unless Keyword.keyword?(compactor_opts) do
      raise ArgumentError,
            "#{prefix} opts for compactor #{inspect(compactor)} must be a keyword list, got " <>
              Describe.type_of(compactor_opts)
    end

    _ = validate_compactor_opts!(compactor, compactor_opts, entry)

    needs_api_lookup? =
      compactor_needs_window?(compactor, compactor_opts) and
        not Keyword.has_key?(compactor_opts, :context_window) and
        catalog_needs_claudio_client?(config)

    if needs_api_lookup? and not match?(%Normandy.LLM.ClaudioAdapter{}, config.client) do
      raise ArgumentError,
            "#{prefix} compactor #{inspect(compactor)} needs the model's " <>
              "context window, and the model catalog #{inspect(catalog)} reads it from the " <>
              "Anthropic Models API, which needs a Normandy.LLM.ClaudioAdapter client; got " <>
              "#{client_kind(config.client)}. Pin the window with the compactor's :context_window " <>
              "option, or configure a model_catalog that works with this client."
    end

    config
  end

  # The compactor checks its own opts (optional Compactor.validate_opts!/2); the result is
  # not used. A /1 (the Hooks and PolicyEngine arity) would be silently ignored, so refuse it.
  defp validate_compactor_opts!(mod, opts, entry) do
    cond do
      not Code.ensure_loaded?(mod) ->
        :ok

      function_exported?(mod, :validate_opts!, 2) ->
        mod.validate_opts!(opts, entry)

      function_exported?(mod, :validate_opts!, 1) ->
        raise ArgumentError,
              "compactor #{inspect(mod)} defines validate_opts!/1, which is never called: " <>
                "the Normandy.Behaviours.Compactor callback is validate_opts!(opts, entry)"

      true ->
        :ok
    end
  end

  @doc false
  # Optional Compactor.needs_window?/1; a compactor that does not say needs one.
  @spec compactor_needs_window?(module(), keyword()) :: boolean()
  def compactor_needs_window?(mod, opts) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :needs_window?, 1),
      do: mod.needs_window?(opts),
      else: true
  end

  # Optional ModelCatalog.needs_claudio_client?/1; a catalog that does not say does not.
  defp catalog_needs_claudio_client?(config) do
    {mod, opts} = catalog_ref(config)

    Code.ensure_loaded?(mod) and function_exported?(mod, :needs_claudio_client?, 1) and
      mod.needs_claudio_client?(opts)
  end

  defp client_kind(%{__struct__: mod}), do: "a #{inspect(mod)}"

  defp client_kind(nil), do: "nil"

  defp client_kind(other) when is_map(other), do: "a plain map"

  defp client_kind(_other), do: "a non-struct value"

  @doc false
  # The model catalog ref of a config; ModelCatalog.ModelsAPI when none is set.
  def catalog_ref(%BaseAgentConfig{behaviours: %Normandy.Behaviours.Config{model_catalog: ref}})
      when not is_nil(ref),
      do: ref

  def catalog_ref(_config), do: {Normandy.Behaviours.ModelCatalog.ModelsAPI, []}
end
