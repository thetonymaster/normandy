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
    - temperature: Sampling temperature (0.0-1.0)
    - max_tokens: Maximum tokens to generate
    - messages: List of conversation messages
    - response_model: Expected response schema
    - opts: Optional keyword list with :tools key for tool schemas

  ## Returns
    Structured response conforming to response_model.

    Implementations may also return `{response, usage}` where `usage` is a
    provider-specific token usage map. Normandy consumes this internally for
    observability without changing the external `BaseAgent.run/2` return shape.
  """
  @spec converse(t(), String.t(), float(), integer(), list(), struct(), keyword()) ::
          struct() | {struct(), map() | nil}
  def converse(config, model, temperature, max_tokens, messages, response_model, opts \\ [])
end
