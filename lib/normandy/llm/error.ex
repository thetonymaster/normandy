defmodule Normandy.LLMError do
  @moduledoc """
  A failed LLM call.

  Adapters return `{:error, %Normandy.LLMError{}}` from `Normandy.Agents.Model.converse/7`;
  `Normandy.Agents.BaseAgent` raises it once retries (if configured) are exhausted.

  - `:type` — failure class (see `t:error_type/0`)
  - `:status` — HTTP status when there was one, else `nil`
  - `:retryable?` — whether a retry can help; set by the adapter that classified the failure
  - `:message` — `"LLM call failed: <type> (<status>): <detail>"`
  - `:reason` — the provider's original error, for debugging

  The message never includes the client, its options or `req_options`.
  """

  @types [
    :rate_limit,
    :overloaded,
    :server,
    :transport,
    :authentication,
    :permission,
    :not_found,
    :invalid_request,
    :invalid_output,
    :stream,
    :circuit_open,
    :unknown
  ]

  defexception [:type, :status, :retryable?, :message, :reason]

  @type error_type ::
          :rate_limit
          | :overloaded
          | :server
          | :transport
          | :authentication
          | :permission
          | :not_found
          | :invalid_request
          | :invalid_output
          | :stream
          | :circuit_open
          | :unknown

  @type t :: %__MODULE__{
          type: error_type(),
          status: non_neg_integer() | nil,
          retryable?: boolean(),
          message: String.t(),
          reason: term()
        }

  @doc """
  Builds an error. `:type` and `:retryable?` are required; `:status`, `:detail` (text for
  the message) and `:reason` are optional.
  """
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields) do
    type = Keyword.fetch!(fields, :type)
    retryable? = Keyword.fetch!(fields, :retryable?)
    status = Keyword.get(fields, :status)

    unless type in @types do
      raise ArgumentError,
            "Normandy.LLMError.new/1: unknown :type #{inspect(type)}, expected one of " <>
              inspect(@types)
    end

    unless is_boolean(retryable?) do
      raise ArgumentError,
            "Normandy.LLMError.new/1: :retryable? must be a boolean, got: #{inspect(retryable?)}"
    end

    %__MODULE__{
      type: type,
      status: status,
      retryable?: retryable?,
      reason: Keyword.get(fields, :reason),
      message: build_message(type, status, Keyword.get(fields, :detail))
    }
  end

  @doc """
  Returns an `LLMError` unchanged; wraps any other term as `type: :unknown`,
  `retryable?: false`, keeping the term in `:reason` (never in the message).
  """
  @spec wrap(term()) :: t()
  def wrap(%__MODULE__{} = error), do: error
  def wrap(reason), do: new(type: :unknown, retryable?: false, reason: reason)

  defp build_message(type, status, detail) do
    status_part = if is_integer(status), do: " (#{status})", else: ""
    detail_part = if is_binary(detail) and detail != "", do: ": " <> detail, else: ""
    "LLM call failed: #{type}#{status_part}#{detail_part}"
  end
end
