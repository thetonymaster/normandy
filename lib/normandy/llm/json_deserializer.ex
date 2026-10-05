defmodule Normandy.LLM.JsonDeserializer do
  @moduledoc """
  JSON deserialization helper with automatic error recovery.

  This module is a thin facade over five focused units under `Normandy.LLM.Json.*`:

  | Unit | Responsibility |
  |------|----------------|
  | `Normandy.LLM.Json.Scanner` | Truncated top-level-string recovery: scans raw bytes to find the safe truncation point and produces a closed-string fragment with balancing closers |
  | `Normandy.LLM.Json.ContentCleaner` | Markdown fence-strip, whitespace trim, and balanced-brace prose extraction via `extract_balanced/1` — isolates the first well-formed JSON object embedded in prose |
  | `Normandy.LLM.Json.Decoder` | Adapter decode with optional truncated-string recovery (delegates to `Scanner`) and a `:max_input_bytes` size guard that short-circuits before any parsing attempt |
  | `Normandy.LLM.Json.SchemaBinder` | Normalises decoded maps, casts and validates against the target schema, and unwraps tool-use `"arguments"` envelopes |
  | `Normandy.LLM.Json.RetryFeedback` | Builds an adapter-encoded corrective retry prompt from the parse error and augments the message history before the next LLM call |

  This module provides robust JSON deserialization with:
  - Automatic retry on JSON parse errors
  - Error feedback to the LLM in a user message after the conversation
  - Configurable retry attempts
  - Support for nested/double-encoded JSON

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
  - `:on_retry_usage` - `(usage -> any)`, called with each retry call's token usage
  - `:request_tracker` - a `Normandy.Telemetry.Request` tracker, passed to each
    retry's `converse/3` (with `request_kind: :json_retry`) so the retry's request
    span is numbered within the enclosing llm_call
  - `:adapter` - a module with `decode/1` and `encode!/2` (default: `Normandy.JSON`)
  - `:recover_truncated_strings` - Opt-in recovery from unclosed top-level
    string truncation (default: `false`). See `parse_and_validate/3`.
  - `:max_input_bytes` - Maximum byte size of the raw content accepted before
    any parsing is attempted (default: `10_000_000`). When the content exceeds
    this limit, `Decoder.decode/3` returns
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

  @default_max_retries 2

  @doc """
  Parse and validate JSON content without retry.

  This is a simpler version of `deserialize_with_retry/5` that performs
  one-shot parsing and validation without LLM retry. Useful for parsing
  final LLM responses where retry is not needed.

  ## Parameters

    - `content` - Raw string content from LLM
    - `schema` - Target schema struct to populate
    - `opts` - Options:
      - `:adapter` - a module with `decode/1` and `encode!/2` (default: `Normandy.JSON`)
      - `:recover_truncated_strings` - When `true`, on adapter decode failure
        attempt one recovery pass for the failure mode "unclosed top-level
        string at depth 1" (e.g. Nemotron-VL `page_text` payloads that
        exhaust max_tokens mid-string). The canonical case is a `\\n`-escape
        runaway tail, but any unclosed depth-1 string also recovers: scan
        truncates at the last non-`\\n`-escape position (or the byte after
        the opening quote if none), appends `"` and the balancing object or
        array closers, re-decodes, and emits
        `[:normandy, :json_deserializer, :recovery]` telemetry on success
        (no `:model`/`:agent_name`; correlate via the enclosing llm_call span,
        same process).
        Truncations inside nested objects or arrays are not recovered. On
        recovery failure the original adapter error is returned unchanged.
        Default: `false`.

  ## Returns

    - `{:ok, populated_schema}` - Success
    - `{:error, reason}` - Parsing or validation failed

  ## Examples

      iex> schema = %BaseAgentOutputSchema{}
      iex> JsonDeserializer.parse_and_validate(~s({"chat_message": "Hello"}), schema)
      {:ok, %BaseAgentOutputSchema{chat_message: "Hello"}}

      iex> JsonDeserializer.parse_and_validate("invalid json", schema)
      {:error, {:json_parse_error, reason, content}}

  """
  @spec parse_and_validate(String.t(), struct(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def parse_and_validate(content, schema, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, Normandy.JSON)
    parse_and_populate(content, schema, adapter, opts)
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
    - `opts` - Options (`:max_retries`, `:on_retry_usage`, `:request_tracker`, `:adapter`,
      `:recover_truncated_strings` — see `parse_and_validate/3` for details)

  ## Returns

    - `{:ok, populated_schema}` - Success
    - `{:error, reason}` - Failed after all retries
  """
  @spec deserialize_with_retry(String.t(), struct(), struct(), Request.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def deserialize_with_retry(content, schema, client, %Request{} = request, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    adapter = Keyword.get(opts, :adapter, Normandy.JSON)

    deserialize_loop(content, schema, client, request, opts, adapter, 0, max_retries)
  end

  # Main retry loop
  defp deserialize_loop(content, schema, _client, _request, opts, adapter, attempt, max_retries)
       when attempt >= max_retries do
    # Max retries reached, attempt final parse and return result
    case parse_and_populate(content, schema, adapter, opts) do
      {:ok, populated_schema} ->
        {:ok, populated_schema}

      {:error, reason} ->
        {:error, {:max_retries_reached, reason}}
    end
  end

  defp deserialize_loop(content, schema, client, request, opts, adapter, attempt, max_retries) do
    case parse_and_populate(content, schema, adapter, opts) do
      {:ok, populated_schema} ->
        {:ok, populated_schema}

      # The clause above handles attempt >= max_retries, so a retry is left.
      {:error, reason} ->
        retry_with_feedback(
          reason,
          content,
          schema,
          client,
          request,
          opts,
          adapter,
          attempt + 1,
          max_retries
        )
    end
  end

  defp report_retry_usage(opts, usage) do
    case Keyword.get(opts, :on_retry_usage) do
      fun when is_function(fun, 1) and not is_nil(usage) -> fun.(usage)
      _ -> :ok
    end
  end

  # Retry by calling the LLM again with error feedback. Each retry augments the
  # original request's messages, not the previous retry's, and asks for text
  # (response_model: nil).
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp retry_with_feedback(
         error,
         failed_content,
         schema,
         client,
         request,
         opts,
         adapter,
         attempt,
         max_retries
       ) do
    error_message = RetryFeedback.build(error, failed_content, schema, adapter)

    retry_request = %{
      request
      | messages: RetryFeedback.augment_messages(request.messages, error_message),
        response_model: nil
    }

    llm_opts = [request_kind: :json_retry] ++ Keyword.take(opts, [:request_tracker])

    case Call.converse(client, retry_request, llm_opts) do
      # An LLM failure is not a parse failure: stop and hand it back.
      {:error, %LLMError{}} = error ->
        error

      {:ok, %Response{content: response, usage: usage}} ->
        report_retry_usage(opts, usage)

        continue_after_retry(
          response,
          schema,
          client,
          request,
          opts,
          adapter,
          attempt,
          max_retries
        )
    end
  end

  defp continue_after_retry(
         response,
         schema,
         client,
         request,
         opts,
         adapter,
         attempt,
         max_retries
       ) do
    cond do
      is_binary(response) ->
        deserialize_loop(response, schema, client, request, opts, adapter, attempt, max_retries)

      is_struct(response) ->
        deserialize_loop(
          extract_content_from_response(response),
          schema,
          client,
          request,
          opts,
          adapter,
          attempt,
          max_retries
        )

      true ->
        {:error, :llm_call_failed}
    end
  end

  defp parse_and_populate(content, schema, adapter, opts) do
    cleaned_content = ContentCleaner.clean(content)

    case Decoder.decode(cleaned_content, adapter, opts) do
      {:ok, parsed} when is_map(parsed) ->
        SchemaBinder.bind(parsed, schema, content)

      {:error, {:input_too_large, _, _} = reason} ->
        {:error, reason}

      {:error, reason} ->
        try_extracted_regions(cleaned_content, 0, adapter, opts, schema, content, reason)

      _ ->
        {:error, {:unexpected_parse_result, content}}
    end
  end

  # Walk successive balanced regions in prose, returning the first that decodes
  # AND binds. A region is skipped when it fails to decode (e.g. a balanced but
  # non-JSON `{note}`) or decodes as valid JSON but fails schema binding (valid
  # JSON of the wrong shape) — so a later valid object is still found. If a
  # region produced a validation error and nothing later binds, that error is
  # preserved rather than masked as a generic json_parse_error.
  defp try_extracted_regions(cleaned_content, offset, adapter, opts, schema, content, reason) do
    case ContentCleaner.extract_balanced(cleaned_content, offset) do
      {:ok, extracted, start} ->
        case Decoder.decode(extracted, adapter, opts) do
          {:ok, parsed} when is_map(parsed) ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case SchemaBinder.bind(parsed, schema, content) do
              {:ok, _populated} = ok ->
                ok

              {:error, bind_reason} ->
                try_extracted_regions(
                  cleaned_content,
                  start + 1,
                  adapter,
                  opts,
                  schema,
                  content,
                  bind_reason
                )
            end

          _ ->
            try_extracted_regions(
              cleaned_content,
              start + 1,
              adapter,
              opts,
              schema,
              content,
              reason
            )
        end

      :error ->
        case reason do
          {:validation_error, _changeset, _content} -> {:error, reason}
          _ -> {:error, {:json_parse_error, reason, content}}
        end
    end
  end

  # Extract content from response struct
  defp extract_content_from_response(%{chat_message: text}) when is_binary(text), do: text

  defp extract_content_from_response(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(Map.get(&1, :type) == :text || Map.get(&1, "type") == "text"))
    |> Enum.map_join("\n", &(Map.get(&1, :text) || Map.get(&1, "text") || ""))
  end

  defp extract_content_from_response(%{content: content}) when is_binary(content), do: content
  defp extract_content_from_response(_), do: ""
end
