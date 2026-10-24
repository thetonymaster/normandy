defprotocol Normandy.Agents.Model do
  @moduledoc """
  The interface between Normandy and a model provider.

  An implementation answers one `Normandy.LLM.Request` at a time:

    * `converse/3` returns the whole answer as `{:ok, %Normandy.LLM.Response{}}`.
    * `stream/3` returns `{:ok, stream}`, an enumerable of stream events (see "Stream
      events"). A client that can't stream returns
      `{:error, %Normandy.LLMError{type: :unsupported, retryable?: false}}`.

  The system prompt to send is `Normandy.LLM.Request.system_prompt/1`: `request.system`
  holds no output schema, which is in `request.output_schema_prompt` so that an adapter
  that constrains the answer to it can leave it out.

  Both return `{:error, %Normandy.LLMError{}}` when the call failed. Set `retryable?` to
  true only when resending the same request can succeed (rate limit, overload, 5xx,
  transport). Normandy raises `ArgumentError` for any other return value.

  ## Response content

  `request.response_model` is an empty struct of the shape the caller expects. Return it
  filled in as `response.content`: `%Normandy.Agents.BaseAgentOutputSchema{}` gets the
  answer text in `:chat_message`, and `%Normandy.Agents.ToolCallResponse{}` gets
  `:content`, `:tool_calls`, `:thinking`, `:stop_reason` (the response's, so a `:pause_turn` is continued) and
  `:content_blocks` (the assistant turn as
  string-keyed, API-shaped blocks, replayed unchanged on the next request; leave it `[]`
  and the turn is rebuilt from the other three). When `response_model` is `nil`, return the
  answer text as a binary.

  An answer that stopped at `:max_tokens`, `:model_context_window_exceeded` or
  `:refusal` need not be parsed: return the empty `response_model` as `content` with that
  `stop_reason`. Normandy turns any response with one of these stop reasons into
  `{:error, %Normandy.LLMError{type: :max_tokens | :refusal}}`, whatever its content.

  `request.output_format`, when set, is the output schema the final answer's text must
  match on a tool-loop call (`response_model: %ToolCallResponse{}`) or a stream. An
  implementation with constrained decoding may send it; the text still goes in
  `:content` (or the stream), and Normandy parses it. Others ignore it.

  ## Options

  `opts` carries Normandy's call plumbing, never request content. An implementation may
  ignore all of it:

    * `:request_tracker` - a `Normandy.Telemetry.Request` tracker, passed by BaseAgent
      (one per llm_call) and by the JSON retry loop
    * `:request_kind` - `:json_retry` when `Normandy.LLM.JsonDeserializer` re-asks after
      an unparseable answer; absent otherwise
    * `:json_retries` - how many times to re-ask after an answer that doesn't parse

  To emit a `[:normandy, :llm, :request]` span per provider request, wrap each request
  in `Normandy.Telemetry.Request.span/5`, passing `opts[:request_tracker]`, the kind
  (`opts[:request_kind]`, or `:structured_fallback`/`nil` as the implementation knows),
  metadata (`%{model: model, provider: :my_provider, stream: false}`), the request
  function, and an outcome function mapping its result to
  `{:ok, Normandy.Telemetry.Request.stop_metadata(id, finish_reason, usage)}` or
  `{:error, %Normandy.LLMError{}}`. With `nil` as the kind the span is `:initial` or
  `:retry` from the tracker's count.

  ## Stream events

  Maps with a string `:type`, in Anthropic SSE order: `"message_start"` (`:message`),
  `"content_block_start"` (`:index`, `:content_block`), `"content_block_delta"`
  (`:index`, `:delta`), `"content_block_stop"` (`:index`), `"message_delta"` (`:delta`,
  `:usage`), `"message_stop"`, `"ping"` and `"error"` (`:error`). Nested maps are
  string-keyed. A transport failure after the stream started is an `{:error, reason}`
  item. `Normandy.Components.StreamProcessor` builds the final message from them, and
  Normandy, not the implementation, delivers them to the caller's callback.
  """

  @doc """
  Makes one model call for `request` and returns `{:ok, %Normandy.LLM.Response{}}` with
  `request.response_model` filled as "Response content" describes, or
  `{:error, %Normandy.LLMError{}}`. Normandy decides whether to retry from the error's
  `retryable?`. Any other return value raises `ArgumentError`.
  """
  @spec converse(t(), Normandy.LLM.Request.t(), keyword()) ::
          {:ok, Normandy.LLM.Response.t()} | {:error, Normandy.LLMError.t()}
  def converse(client, request, opts)

  @doc """
  Starts one streaming model call for `request` and returns `{:ok, stream}`, an enumerable of
  the events in "Stream events", or `{:error, %Normandy.LLMError{}}`. A client that cannot
  stream returns `{:error, %Normandy.LLMError{type: :unsupported, retryable?: false}}`.
  """
  @spec stream(t(), Normandy.LLM.Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Normandy.LLMError.t()}
  def stream(client, request, opts)
end
