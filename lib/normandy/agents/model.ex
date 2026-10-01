defprotocol Normandy.Agents.Model do
  @moduledoc """
  Protocol for LLM model interactions.

  Defines the interface for conversing with language models, supporting both
  structured outputs and tool calling capabilities.
  """

  @spec completitions(
          t(),
          String.t(),
          float(),
          integer(),
          binary(),
          struct()
        ) :: struct()
  def completitions(config, model, temperature, max_tokens, messages, response_model)

  @doc """
  Converse with the model, optionally providing tool schemas.

  ## Parameters
    - config: Model client configuration
    - model: Model identifier
    - temperature: Sampling temperature, or nil to leave it unset (Opus 4.7+ reject sampling parameters)
    - max_tokens: Maximum tokens to generate
    - messages: List of conversation messages
    - response_model: Expected response schema
    - opts: Optional keyword list with :tools key for tool schemas

  ## Returns
    Structured response conforming to response_model.

    Implementations may also return `{response, usage}` or
    `{response, usage, meta}`: `usage` is a provider-specific token usage map,
    `meta` a map of per-call facts (e.g. `:served_by`). Normandy consumes both
    internally for observability (see `Normandy.Agents.ConverseResult`) without
    changing the external `BaseAgent.run/2` return shape.

    Implementations may also return `{:error, %Normandy.LLMError{}}` when the call
    failed. Set `retryable?` to true only when resending the same request can
    succeed (rate limit, overload, 5xx, transport).
  """
  @spec converse(t(), String.t(), float() | nil, integer() | nil, list(), struct(), keyword()) ::
          struct()
          | {struct(), map() | nil}
          | {struct(), map() | nil, map()}
          | {:error, Normandy.LLMError.t()}
  def converse(config, model, temperature, max_tokens, messages, response_model, opts \\ [])
end
