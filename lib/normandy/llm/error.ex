defmodule Normandy.LLMError do
  @moduledoc """
  A failed LLM call.

  Adapters return `{:error, %Normandy.LLMError{}}` from `Normandy.Agents.Model.converse/3`;
  Once retries (if configured) are exhausted, `Normandy.Agents.BaseAgent.run/3` returns it
  as `{:error, %Normandy.LLMError{}}` and `run!/3` raises it.

  `type: :unsupported` means the client can't do what was asked (a client without
  streaming answering `Normandy.Agents.Model.stream/3`); it is never retryable.

  `type: :max_tokens` means the answer stopped before it was complete: the response hit
  the request's `max_tokens`, or the context window (`model_context_window_exceeded`; the
  message names which). `type: :refusal` means the model declined to answer. Both are
  `retryable?: false`; `:reason` is `{:stop_reason, reason}`, never model text, and
  `:usage` is what the call billed. Normandy builds them from the response's
  `stop_reason`, so every client gets them.

  `type: :pause_turn` means the final call after `max_tool_iterations` was still paused
  (`stop_reason` `pause_turn`) after three continuations. It is `retryable?: false`;
  `:reason` is `{:stop_reason, :pause_turn}`, never model text, and `:usage` is the paused
  response's own when it carries any (BaseAgent's do not: each call's usage is on its
  `llm_call` span). The turn core builds it, so no circuit breaker counts it.

  - `:type` — failure class (see `t:error_type/0`)
  - `:status` — HTTP status when there was one, else `nil`
  - `:retryable?` — whether a retry can help; set by the adapter that classified the failure
  - `:message` — `"LLM call failed: <type> (<status>): <detail>"`
  - `:reason` — the provider's original error, for debugging
  - `:usage` — raw token usage already paid for before the call failed (for example the
    first response plus JSON-parse retries that ended in `:invalid_output`), `nil` when
    no call was billed
  - `:usage_counts` — the same usage normalized by `Normandy.Telemetry.Usage.normalize/1`
    (`:input_tokens`, `:output_tokens`, ...), `nil` when `:usage` is

  The llm_call span's `[:normandy, :agent, :llm_call, :exception]` metadata cannot carry
  extra keys, so this usage is read from its `reason`: `metadata.reason.usage` and
  `metadata.reason.usage_counts`.

  The message never includes the client, its options or `req_options`.
  """

  alias Normandy.Telemetry.Usage

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
    :max_tokens,
    :refusal,
    :pause_turn,
    :stream,
    :circuit_open,
    :unsupported,
    :unknown
  ]

  defexception [:type, :status, :retryable?, :message, :reason, :usage, :usage_counts]

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
          | :max_tokens
          | :refusal
          | :pause_turn
          | :stream
          | :circuit_open
          | :unsupported
          | :unknown

  @type t :: %__MODULE__{
          type: error_type(),
          status: non_neg_integer() | nil,
          retryable?: boolean(),
          message: String.t(),
          reason: term(),
          usage: map() | struct() | nil,
          usage_counts: Usage.normalized() | nil
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
  Attaches the raw usage already billed before the failure (and its normalized counts).
  A `nil` usage is ignored, and the first usage wins: an error that already carries usage
  is returned unchanged.
  """
  @spec with_usage(t(), map() | struct() | nil) :: t()
  def with_usage(%__MODULE__{usage: nil} = error, usage) when not is_nil(usage) do
    %{error | usage: usage, usage_counts: Usage.normalize(usage)}
  end

  def with_usage(%__MODULE__{} = error, _usage), do: error

  @doc """
  Returns an `LLMError` unchanged; wraps any other term as `type: :unknown`,
  `retryable?: false`, keeping the term in `:reason` (never in the message).
  """
  @spec wrap(term()) :: t()
  def wrap(%__MODULE__{} = error), do: error
  def wrap(reason), do: new(type: :unknown, retryable?: false, reason: reason)

  @doc false
  # The one HTTP-status rule of every adapter: {type, retryable?}. No status is a retryable
  # :server error; 529 is :overloaded.
  @spec classify_status(integer() | nil) :: {atom(), boolean()}
  def classify_status(nil), do: {:server, true}
  def classify_status(429), do: {:rate_limit, true}
  def classify_status(529), do: {:overloaded, true}
  def classify_status(408), do: {:server, true}
  def classify_status(status) when status >= 500, do: {:server, true}
  def classify_status(401), do: {:authentication, false}
  def classify_status(403), do: {:permission, false}
  def classify_status(404), do: {:not_found, false}
  def classify_status(status) when status >= 400, do: {:invalid_request, false}
  def classify_status(_status), do: {:unknown, false}

  @doc false
  # A transport failure (Req/Mint exception): retryable, the exception kept as the reason.
  @spec transport(Exception.t()) :: t()
  def transport(exception),
    do:
      new(
        type: :transport,
        retryable?: true,
        detail: Exception.message(exception),
        reason: exception
      )

  defp build_message(type, status, detail) do
    status_part = if is_integer(status), do: " (#{status})", else: ""
    detail_part = if is_binary(detail) and detail != "", do: ": " <> detail, else: ""
    "LLM call failed: #{type}#{status_part}#{detail_part}"
  end
end
