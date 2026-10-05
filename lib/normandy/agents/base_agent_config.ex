defmodule Normandy.Agents.BaseAgentConfig do
  @moduledoc """
  Configuration structure for BaseAgent instances.

  Stores all stateful information for an agent including schemas,
  memory, model configuration, and prompt specifications.

  Option groups: `retry` (`Normandy.Resilience.Retry` options or `nil`), `circuit_breaker`
  (`Normandy.Resilience.CircuitBreaker` options or `nil`; `circuit_breaker_pid` is the
  breaker `BaseAgent.init/1` started, node-local) and `guardrails`
  (`[input:, output:, streaming_mode:, chunk_size:, on_violation:]`). A `guardrails` list
  built by hand may leave keys out: `guardrail/2` reads a missing key as its default.
  """

  use Normandy.Schema

  alias Normandy.Components.PromptSpecification
  alias Normandy.Tools.Registry

  # The Messages API requires max_tokens; a nil here would drop the key and
  # every request would get a 400.
  @default_max_tokens 16_000

  @doc "The `max_tokens` used when a config sets none: #{@default_max_tokens}."
  @spec default_max_tokens() :: pos_integer()
  def default_max_tokens, do: @default_max_tokens

  @default_guardrails [
    input: [],
    output: [],
    streaming_mode: :accumulate,
    chunk_size: 200,
    on_violation: :block
  ]

  @typedoc "The `guardrails` group; see `Normandy.Guardrails`."
  @type guardrails :: [
          input: [Normandy.Guardrails.spec()],
          output: [Normandy.Guardrails.spec()],
          streaming_mode: :accumulate | :incremental,
          chunk_size: pos_integer(),
          on_violation: :block | :warn
        ]

  @type t :: %__MODULE__{
          input_schema: struct(),
          output_schema: struct(),
          client: struct(),
          model: String.t(),
          memory: map(),
          prompt_specification: PromptSpecification.t(),
          initial_memory: map(),
          current_user_input: String.t() | nil,
          temperature: float() | nil,
          max_tokens: pos_integer(),
          tool_registry: Registry.t() | nil,
          max_tool_iterations: pos_integer(),
          max_tool_concurrency: pos_integer(),
          retry: keyword() | nil,
          circuit_breaker: keyword() | nil,
          circuit_breaker_pid: pid() | nil,
          enable_json_retry: boolean(),
          json_retry_max_attempts: pos_integer(),
          name: String.t() | nil,
          mcp_servers: list() | nil,
          guardrails: guardrails(),
          behaviours: Normandy.Behaviours.Config.t() | nil,
          resolved_context_window: {String.t(), pos_integer()} | nil,
          session_id: String.t() | nil,
          tool_context: map()
        }

  @typedoc "Any `%BaseAgentConfig{}`, including a partially filled one (field types unchecked)."
  @type partial() :: %__MODULE__{}

  schema do
    field(:name, :string, default: nil)
    field(:input_schema, :struct)
    field(:output_schema, :struct)
    field(:client, :struct)
    field(:model, :string)
    field(:memory, :map)
    field(:prompt_specification, :struct)
    field(:initial_memory, :map)
    field(:current_user_input, :string, default: nil)
    field(:temperature, :float, default: nil)
    field(:max_tokens, :integer, default: @default_max_tokens)
    field(:tool_registry, :struct, default: nil)
    field(:max_tool_iterations, :integer, default: 5)
    field(:max_tool_concurrency, :integer, default: 1)
    field(:retry, :any, default: nil)
    field(:circuit_breaker, :any, default: nil)
    field(:circuit_breaker_pid, :any, default: nil)
    field(:enable_json_retry, :boolean, default: true)
    field(:json_retry_max_attempts, :integer, default: 2)
    field(:mcp_servers, :any, default: nil)
    field(:guardrails, :any, default: @default_guardrails)
    field(:behaviours, :any, default: nil)
    field(:resolved_context_window, :any, default: nil)
    field(:session_id, :string, default: nil)
    field(:tool_context, :map, default: %{})
  end

  @doc "The `guardrails` a config has when it sets none."
  @spec default_guardrails() :: guardrails()
  def default_guardrails, do: @default_guardrails

  @doc """
  One `guardrails` setting of `config`; a key left out of a hand-built `guardrails` list
  reads as its default (`default_guardrails/0`).
  """
  @spec guardrail(t(), :input | :output | :streaming_mode | :chunk_size | :on_violation) ::
          term()
  def guardrail(%__MODULE__{guardrails: guardrails}, key) when is_list(guardrails),
    do: Keyword.get_lazy(guardrails, key, fn -> Keyword.fetch!(@default_guardrails, key) end)
end
