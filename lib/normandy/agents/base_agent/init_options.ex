defmodule Normandy.Agents.BaseAgent.InitOptions do
  @moduledoc false
  # The `BaseAgent.init/1` option schema, its custom checks, and hints for option names a
  # caller might reasonably try. `Normandy.DSL.Agent`'s generated `new/1` uses the same
  # definition (without defaults), so both entry points accept the same options.

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Options
  alias Normandy.Resilience.Retry

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
    tool_registry: [
      type: {:or, [{:struct, Normandy.Tools.Registry}, nil]},
      default: nil,
      type_doc: "a `Normandy.Tools.Registry` or `nil`",
      doc: "The agent's tools."
    ],
    max_tool_iterations: [type: :pos_integer, default: 5, doc: "Tool rounds per turn."],
    max_tool_concurrency: [
      type: {:custom, __MODULE__, :max_tool_concurrency, []},
      default: 1,
      type_doc: "`t:integer/0`",
      doc: "Tool calls run at once; a value below 1 counts as 1."
    ],
    retry_options: [
      type: {:custom, __MODULE__, :retry, []},
      default: nil,
      type_doc: "`t:keyword/0` or `nil`",
      doc: "`Normandy.Resilience.Retry` options for LLM calls; `nil` makes one attempt."
    ],
    enable_circuit_breaker: [
      type: :boolean,
      default: false,
      doc: "Starts a `Normandy.Resilience.CircuitBreaker` linked to the caller."
    ],
    circuit_breaker_options: [
      type: :keyword_list,
      default: [],
      keys: [
        failure_threshold: [type: :pos_integer, doc: "Failures before it opens."],
        success_threshold: [type: :pos_integer, doc: "Successes that close it from half-open."],
        timeout: [type: :pos_integer, doc: "Milliseconds open before half-open."],
        half_open_max_calls: [type: :pos_integer, doc: "Calls let through when half-open."]
      ],
      doc: "The circuit breaker's options."
    ],
    enable_json_retry: [
      type: :boolean,
      default: true,
      doc: "Asks the model again when its JSON does not parse."
    ],
    json_retry_max_attempts: [type: :pos_integer, default: 2, doc: "JSON re-asks per call."],
    input_guardrails: [
      type: {:list, @guard_spec},
      default: [],
      doc: "Guards for the input (`Normandy.Guardrails`)."
    ],
    output_guardrails: [
      type: {:list, @guard_spec},
      default: [],
      doc: "Guards for the answer (`Normandy.Guardrails`)."
    ],
    output_guardrails_streaming_mode: [
      type: {:in, [:accumulate, :incremental]},
      default: :accumulate,
      doc: "When `stream/3` checks the output guards."
    ],
    output_guardrails_chunk_size: [
      type: :pos_integer,
      default: 200,
      doc: "Bytes of streamed text between incremental checks."
    ],
    output_guardrails_on_violation: [
      type: {:in, [:block, :warn]},
      default: :block,
      doc: "What an output violation does."
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
      "tools go in :tool_registry (Normandy.Tools.Registry.new([tool, ...])) or are added " <>
        "after init with BaseAgent.register_tool/2",
    max_messages:
      "cap the memory with memory: Normandy.Components.AgentMemory.new_memory(max_messages)"
  ]

  @init {BaseAgent, :init, 1}

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
  # Raises for a key in @hints that `schema` does not itself accept, naming the key, where
  # the setting lives, and `schema`'s options.
  @spec check_misnamed!(term(), NimbleOptions.t(), {module(), atom(), arity()}) :: :ok
  def check_misnamed!(opts, %NimbleOptions{} = schema, {mod, fun, arity}) do
    keys = option_keys(opts)
    supported = Keyword.keys(schema.schema)

    case Enum.find(@hints, fn {key, _hint} -> key in keys and key not in supported end) do
      nil ->
        :ok

      {key, hint} ->
        raise ArgumentError,
              "#{inspect(mod)}.#{fun}/#{arity}: unknown option #{inspect(key)}; #{hint}; " <>
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
  def client(%_{} = client), do: {:ok, client}
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
    do: {:ok, BaseAgent.normalize_max_tool_concurrency(n)}

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
end
