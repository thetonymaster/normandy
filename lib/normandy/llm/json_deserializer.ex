defmodule Normandy.LLM.JsonDeserializer do
  @moduledoc """
  JSON deserialization helper with automatic error recovery.

  It strips Markdown fences and surrounding prose, decodes through `Normandy.JSON` (with a `:max_input_bytes` guard),
  casts and validates the result against the target schema, and builds the corrective
  retry prompt after a parse error.

  This module provides robust JSON deserialization with:
  - Automatic retry on JSON parse errors
  - Error feedback to the LLM in a user message after the conversation
  - Configurable retry attempts

  ## Usage with Agent

      # Retry is on by default (2 retries); each retry is a paid LLM call whose
      # token usage is added to the reported usage.
      agent = BaseAgent.init(%{
        client: client,
        model: "claude-opus-5-5",
        json_retry_max_attempts: 3         # default: 2
        # enable_json_retry: false         # no retries
      })

      {:ok, agent, response} = BaseAgent.run(agent, input)

  ## Manual Usage

      request = %Normandy.LLM.Request{model: model, messages: messages, max_tokens: 1024}

      # With default retries (2)
      {:ok, schema} = JsonDeserializer.deserialize_with_retry(raw_content, schema, client, request)

      # With custom retries
      {:ok, schema} =
        JsonDeserializer.deserialize_with_retry(raw_content, schema, client, request,
          max_retries: 3
        )

  ## How It Works

  1. Attempts to parse JSON response
  2. On error, adds a user message with the error details
  3. Retries LLM call with error feedback
  4. Repeats until success or max_retries reached

  ## Configuration

  ### Call-site options

  - `:max_retries` - Maximum retry attempts (default: 2)
  - `:on_retry_usage` - `(usage -> any)`, called with each retry call's token usage as
    that retry finishes (a billed failure included)
  - `:request_tracker` - a `Normandy.Telemetry.Request` tracker, passed to each
    retry's `converse/3` (with `request_kind: :json_retry`) so the retry's request
    span is numbered within the enclosing llm_call
  - `:max_input_bytes` - Maximum byte size of the raw content accepted before
    any parsing is attempted (default: `10_000_000`). When the content exceeds
    this limit, the parse returns
    `{:error, {:input_too_large, actual_size, limit}}` immediately, skipping
    all JSON parsing and schema binding.

  ### Application config

  - `:on_parse_failure` - Controls the behaviour of `Normandy.LLM.ClaudioAdapter`
    when JSON deserialization fails after all retries are exhausted.
    Set per client with `options: %{on_parse_failure: ...}`, or for all clients
    under the `:normandy` application key:

        config :normandy, :on_parse_failure, :fallback   # default

    Accepted values:

    - `:fallback` (default) — Returns the response schema with `chat_message`
      set to the raw LLM text (unchanged when the output is not text), emits a
      `Logger.warning`, and fires `[:normandy, :json_deserializer, :fallback]`
      telemetry with `%{reason: tag, content_bytes: n}`. Neither carries the
      model output, which can hold user data. The event has no `:model` or
      `:agent_name`: the parser is not given them, and Normandy keeps no
      process-global state to look them up. Correlate through the enclosing
      `[:normandy, :agent, :llm_call]` span, which runs in the same process.
    - `:error` — Returns `{:error, %Normandy.LLMError{type: :invalid_output, reason: reason}}`
      to the caller; no fallback text is produced.

  ## Retries

  On a parse failure the loop calls `Normandy.Agents.Model.converse/3` again with the
  error feedback appended to `request.messages` and `response_model: nil`, which asks
  the client for the answer as text. Every attempt, initial or corrective, is parsed
  here (`parse_and_populate/4`), so this module is the single parse-and-retry
  authority. A client that ignores `response_model: nil` and returns a struct still
  works: its text is extracted and parsed.
  """

  alias Normandy.LLM.Call
  alias Normandy.LLM.Json.ContentCleaner
  alias Normandy.LLM.Json.Decoder
  alias Normandy.LLM.Json.RetryFeedback
  alias Normandy.LLM.Json.SchemaBinder
  alias Normandy.LLM.Request
  alias Normandy.LLM.Response
  alias Normandy.LLMError
  alias Normandy.Options

  @parse_opts_schema NimbleOptions.new!(
                       max_input_bytes: [
                         type: :pos_integer,
                         default: 10_000_000,
                         doc: "Largest raw content, in bytes, parsed at all."
                       ]
                     )

  @retry_opts_schema NimbleOptions.new!(
                       max_retries: [type: :non_neg_integer, default: 2, doc: "Re-asks."],
                       on_retry_usage: [
                         type: {:fun, 1},
                         doc: "Called with each retry call's token usage as it finishes."
                       ],
                       request_tracker: [
                         type: :any,
                         doc: "A `Normandy.Telemetry.Request` tracker, or `nil`."
                       ],
                       max_input_bytes: [
                         type: :pos_integer,
                         default: 10_000_000,
                         doc: "Largest raw content, in bytes, parsed at all."
                       ]
                     )

  @usage_opts_schema NimbleOptions.new!(
                       Keyword.delete(@retry_opts_schema.schema, :on_retry_usage)
                     )

  @doc """
  Parse and validate JSON content without retry.

  This is a simpler version of `deserialize_with_retry/5` that performs
  one-shot parsing and validation without LLM retry. Useful for parsing
  final LLM responses where retry is not needed.

  ## Parameters

    - `content` - Raw string content from LLM
    - `schema` - Target schema struct to populate
    - `opts` - Options (`:max_input_bytes`); an unknown option raises `ArgumentError`
    
  ## Returns

    - `{:ok, populated_schema}` - Success
    - `{:error, reason}` - Parsing or validation failed

  ## Examples

      schema = %BaseAgentOutputSchema{}
      JsonDeserializer.parse_and_validate(~s({"chat_message": "Hello"}), schema)
      #=> {:ok, %BaseAgentOutputSchema{chat_message: "Hello"}}

      JsonDeserializer.parse_and_validate("invalid json", schema)
      #=> {:error, {:json_parse_error, reason, content}}

  """
  @spec parse_and_validate(String.t(), struct(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def parse_and_validate(content, schema, opts \\ []) do
    opts = Options.validate!(opts, @parse_opts_schema, {__MODULE__, :parse_and_validate, 3})
    parse_and_populate(content, schema, opts)
  end

  @doc """
  Deserialize JSON content with automatic retry on errors.

  If initial deserialization fails, this function:
  1. Extracts the error message
  2. Adds a user message with the error details
  3. Calls the LLM again with feedback
  4. Attempts deserialization again

  ## Parameters

    - `content` - Raw string content from LLM
    - `schema` - Target schema struct to populate
    - `client` - LLM client
    - `request` - the `Normandy.LLM.Request` that produced `content`; a retry resends
      it with the error feedback appended to its messages
    - `opts` - Options (`:max_retries`, `:on_retry_usage`, `:request_tracker`, `:max_input_bytes`)

  ## Returns

    - `{:ok, populated_schema}` - Success
    - `{:error, reason}` - Failed after all retries
  """
  @spec deserialize_with_retry(String.t(), struct(), struct(), Request.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def deserialize_with_retry(content, schema, client, %Request{} = request, opts \\ []) do
    opts = Options.validate!(opts, @retry_opts_schema, {__MODULE__, :deserialize_with_retry, 5})

    {result, _usages} =
      run(content, schema, client, request, opts, Keyword.get(opts, :on_retry_usage))

    result
  end

  @doc false
  # Like `deserialize_with_retry/5`, and the caller owns the usage: returns the
  # result and the token usage of every retry call, in order, an LLM failure's
  # usage included (it is taken off the error). `:on_retry_usage` is not allowed.
  @spec deserialize_with_usage(String.t(), struct(), struct(), Request.t(), keyword()) ::
          {{:ok, struct()} | {:error, term()}, [map()]}
  def deserialize_with_usage(content, schema, client, %Request{} = request, opts \\ []) do
    opts =
      Options.validate!(
        opts,
        @usage_opts_schema,
        {__MODULE__, :deserialize_with_usage, 5}
      )

    run(content, schema, client, request, opts, :collect)
  end

  # `usage_sink` is how the caller takes the retries' usage: a 1-arity function
  # called as each retry is billed, or `:collect` (returned in the list). Either
  # way a billed failure's usage is taken off the error; with `nil`, the error
  # keeps its usage for a direct caller to see.
  defp run(content, schema, client, request, opts, usage_sink) do
    run = %{
      schema: schema,
      client: client,
      request: request,
      opts: opts,
      max_retries: Keyword.fetch!(opts, :max_retries),
      usage_sink: usage_sink
    }

    deserialize_loop(content, run, 0, [])
  end

  # Main retry loop: only `content` and `attempt` change; `usages` is the retry
  # calls' usage so far, newest first.
  defp deserialize_loop(content, run, attempt, usages) do
    case parse_and_populate(content, run.schema, run.opts) do
      {:ok, populated_schema} ->
        {{:ok, populated_schema}, Enum.reverse(usages)}

      {:error, reason} when attempt >= run.max_retries ->
        {{:error, {:max_retries_reached, reason}}, Enum.reverse(usages)}

      {:error, reason} ->
        retry_with_feedback(reason, content, run, attempt + 1, usages)
    end
  end

  # Retry by calling the LLM again with error feedback. Each retry augments the
  # original request's messages, not the previous retry's, and asks for text
  # (response_model: nil).
  defp retry_with_feedback(error, failed_content, run, attempt, usages) do
    error_message = RetryFeedback.build(error, failed_content, run.schema)

    retry_request = %{
      run.request
      | messages: RetryFeedback.augment_messages(run.request.messages, error_message),
        response_model: nil
    }

    llm_opts = [request_kind: :json_retry] ++ Keyword.take(run.opts, [:request_tracker])

    case Call.converse(run.client, retry_request, llm_opts) do
      # An LLM failure is not a parse failure: stop and hand it back. A billed failure
      # (a retry cut off at max_tokens) reports its usage like a successful retry, so the
      # adapter attaches the call's total instead of this retry's alone.
      {:error, %LLMError{} = error} ->
        hand_off_failure(error, run, usages)

      {:ok, %Response{content: response, usage: usage}} ->
        usages = add_usage(usages, usage, run)

        case response_text(response) do
          {:ok, text} -> deserialize_loop(text, run, attempt, usages)
          :error -> {{:error, :llm_call_failed}, Enum.reverse(usages)}
        end
    end
  end

  defp hand_off_failure(error, %{usage_sink: nil}, usages),
    do: {{:error, error}, Enum.reverse(usages)}

  defp hand_off_failure(error, run, usages) do
    {{:error, %{error | usage: nil, usage_counts: nil}},
     Enum.reverse(add_usage(usages, error.usage, run))}
  end

  defp add_usage(usages, nil, _run), do: usages

  defp add_usage(usages, usage, %{usage_sink: sink}) do
    if is_function(sink, 1), do: sink.(usage)
    [usage | usages]
  end

  defp response_text(response) when is_binary(response), do: {:ok, response}

  defp response_text(response) when is_struct(response),
    do: {:ok, extract_content_from_response(response)}

  defp response_text(_response), do: :error

  defp parse_and_populate(content, schema, opts) do
    cleaned_content = ContentCleaner.clean(content)

    case Decoder.decode(cleaned_content, opts) do
      {:ok, parsed} when is_map(parsed) ->
        SchemaBinder.bind(parsed, schema, content)

      {:error, {:input_too_large, _, _} = reason} ->
        {:error, reason}

      {:error, reason} ->
        try_extracted_regions(cleaned_content, opts, schema, content, reason)

      _ ->
        {:error, {:unexpected_parse_result, content}}
    end
  end

  # Walk the balanced regions in prose, returning the first that decodes AND
  # binds. A region is skipped when it fails to decode (e.g. a balanced but
  # non-JSON `{note}`) or decodes as valid JSON but fails schema binding (valid
  # JSON of the wrong shape) — so a later valid object is still found. If a
  # region produced a validation error and nothing later binds, that error is
  # preserved rather than masked as a generic json_parse_error.
  #
  # Regions nest, so their sizes add up to more than the content's (`[[[...]]]`
  # has one region per level): the regions together may cost at most `8 * size + 1024`
  # bytes of decoding (a failed decode costs the bytes read up to its error), then
  # the walk stops with the reason so far.
  defp try_extracted_regions(cleaned_content, opts, schema, content, reason) do
    budget = 8 * byte_size(cleaned_content) + 1024

    {result, _budget} =
      cleaned_content
      |> ContentCleaner.balanced_regions()
      |> Enum.reduce_while({reason, budget}, fn {extracted, _start}, {reason, budget} ->
        {tag, reason, cost} = bind_region(extracted, opts, schema, content, reason)

        case budget - cost do
          left when left < 0 -> {:halt, {reason, left}}
          left -> {tag, {reason, left}}
        end
      end)

    case result do
      {:ok, _populated} = ok -> ok
      {:validation_error, _changeset, _content} = reason -> {:error, reason}
      reason -> {:error, {:json_parse_error, reason, content}}
    end
  end

  # {:cont | :halt, reason_or_result, bytes read}. A decode that fails costs the
  # bytes it read before the failure, not the region's size.
  defp bind_region(extracted, opts, schema, content, reason) do
    case Decoder.decode(extracted, opts) do
      {:ok, parsed} when is_map(parsed) ->
        case SchemaBinder.bind(parsed, schema, content) do
          {:ok, _populated} = ok -> {:halt, ok, 0}
          {:error, bind_reason} -> {:cont, bind_reason, byte_size(extracted)}
        end

      {:ok, _not_a_map} ->
        {:cont, reason, byte_size(extracted)}

      {:error, %{position: position}} when is_integer(position) ->
        {:cont, reason, position + 1}

      _ ->
        {:cont, reason, byte_size(extracted)}
    end
  end

  # Extract content from response struct. Any Model client may have built it, not only
  # Claudio (whose blocks are atom-keyed), so both key styles stay.
  defp extract_content_from_response(%{chat_message: text}) when is_binary(text), do: text

  defp extract_content_from_response(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(Map.get(&1, :type) == :text || Map.get(&1, "type") == "text"))
    |> Enum.map_join("\n", &(Map.get(&1, :text) || Map.get(&1, "text") || ""))
  end

  defp extract_content_from_response(%{content: content}) when is_binary(content), do: content
  defp extract_content_from_response(_), do: ""
end
