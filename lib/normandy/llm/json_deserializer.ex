defmodule Normandy.LLM.JsonDeserializer do
  @moduledoc """
  JSON deserialization helper with automatic error recovery.

  This module provides robust JSON deserialization with:
  - Automatic retry on JSON parse errors
  - Error feedback to LLM via system prompt augmentation
  - Configurable retry attempts
  - Support for nested/double-encoded JSON

  ## Usage with Agent

      # Enable in agent config
      agent = BaseAgent.init(%{
        client: client,
        model: "claude-3-5-sonnet-20241022",
        temperature: 0.7,
        enable_json_retry: true,           # Enable automatic retry
        json_retry_max_attempts: 3         # Optional: default is 2
      })

      # The agent will automatically retry on JSON parse errors
      {agent, response} = BaseAgent.run(agent, input)

  ## Manual Usage

      # With default retries (2)
      {:ok, schema} = JsonDeserializer.deserialize_with_retry(
        raw_content,
        schema,
        client,
        model,
        temperature,
        max_tokens,
        messages
      )

      # With custom retries
      {:ok, schema} = JsonDeserializer.deserialize_with_retry(
        raw_content,
        schema,
        client,
        model,
        temperature,
        max_tokens,
        messages,
        max_retries: 3
      )

  ## How It Works

  1. Attempts to parse JSON response
  2. On error, augments system prompt with error details
  3. Retries LLM call with error feedback
  4. Repeats until success or max_retries reached

  ## Configuration

  Options:
  - `:max_retries` - Maximum retry attempts (default: 2)
  - `:tools` - Tool schemas to include in retry
  - `:adapter` - JSON adapter module (default: from :normandy app config)
  - `:recover_truncated_strings` - Opt-in recovery from unclosed top-level
    string truncation (default: `false`). See `parse_and_validate/3`.
  """

  alias Normandy.LLM.Json.ContentCleaner
  alias Normandy.LLM.Json.Decoder
  alias Normandy.LLM.Json.RetryFeedback
  alias Normandy.LLM.Json.SchemaBinder

  @default_max_retries 2

  @doc """
  Parse and validate JSON content without retry.

  This is a simpler version of `deserialize_with_retry/8` that performs
  one-shot parsing and validation without LLM retry. Useful for parsing
  final LLM responses where retry is not needed.

  ## Parameters

    - `content` - Raw string content from LLM
    - `schema` - Target schema struct to populate
    - `opts` - Options:
      - `:adapter` - JSON adapter module (default: from `:normandy` app config)
      - `:recover_truncated_strings` - When `true`, on adapter decode failure
        attempt one recovery pass for the failure mode "unclosed top-level
        string at depth 1" (e.g. Nemotron-VL `page_text` payloads that
        exhaust max_tokens mid-string). The canonical case is a `\\n`-escape
        runaway tail, but any unclosed depth-1 string also recovers: scan
        truncates at the last non-`\\n`-escape position (or the byte after
        the opening quote if none), appends `"` and the balancing object or
        array closers, re-decodes, and emits
        `[:normandy, :json_deserializer, :recovery]` telemetry on success.
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
    adapter = Keyword.get(opts, :adapter, get_json_adapter())
    parse_and_populate(content, schema, adapter, opts)
  end

  @doc """
  Deserialize JSON content with automatic retry on errors.

  If initial deserialization fails, this function:
  1. Extracts the error message
  2. Augments the system prompt with error details
  3. Calls the LLM again with feedback
  4. Attempts deserialization again

  ## Parameters

    - `content` - Raw string content from LLM
    - `schema` - Target schema struct to populate
    - `client` - LLM client
    - `model` - Model name
    - `temperature` - Temperature setting
    - `max_tokens` - Max tokens
    - `messages` - Original message history
    - `opts` - Options (`:max_retries`, `:tools`, `:adapter`,
      `:recover_truncated_strings` — see `parse_and_validate/3` for details)

  ## Returns

    - `{:ok, populated_schema}` - Success
    - `{:error, reason}` - Failed after all retries
  """
  @spec deserialize_with_retry(
          String.t(),
          struct(),
          struct(),
          String.t(),
          float() | nil,
          integer() | nil,
          list(),
          keyword()
        ) :: {:ok, struct()} | {:error, term()}
  def deserialize_with_retry(
        content,
        schema,
        client,
        model,
        temperature,
        max_tokens,
        messages,
        opts \\ []
      ) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    adapter = Keyword.get(opts, :adapter, get_json_adapter())

    deserialize_loop(
      content,
      schema,
      client,
      model,
      temperature,
      max_tokens,
      messages,
      opts,
      adapter,
      0,
      max_retries
    )
  end

  # Main retry loop
  defp deserialize_loop(
         content,
         schema,
         _client,
         _model,
         _temperature,
         _max_tokens,
         _messages,
         opts,
         adapter,
         attempt,
         max_retries
       )
       when attempt >= max_retries do
    # Max retries reached, attempt final parse and return result
    case parse_and_populate(content, schema, adapter, opts) do
      {:ok, populated_schema} ->
        {:ok, populated_schema}

      {:error, reason} ->
        {:error, {:max_retries_reached, reason}}
    end
  end

  defp deserialize_loop(
         content,
         schema,
         client,
         model,
         temperature,
         max_tokens,
         messages,
         opts,
         adapter,
         attempt,
         max_retries
       ) do
    case parse_and_populate(content, schema, adapter, opts) do
      {:ok, populated_schema} ->
        {:ok, populated_schema}

      {:error, reason} when attempt < max_retries ->
        # Parse failed, retry with error feedback
        retry_with_feedback(
          reason,
          content,
          schema,
          client,
          model,
          temperature,
          max_tokens,
          messages,
          opts,
          adapter,
          attempt + 1,
          max_retries
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Retry by calling LLM again with error feedback
  defp retry_with_feedback(
         error,
         failed_content,
         schema,
         client,
         model,
         temperature,
         max_tokens,
         messages,
         opts,
         adapter,
         attempt,
         max_retries
       ) do
    # Build error feedback message
    error_message = RetryFeedback.build(error, failed_content, schema)

    # Augment system prompt with error feedback
    augmented_messages = RetryFeedback.augment_messages(messages, error_message)

    # Call LLM again
    tools = Keyword.get(opts, :tools, [])
    llm_opts = if tools != [], do: [tools: tools], else: []

    case Normandy.Agents.Model.converse(
           client,
           model,
           temperature,
           max_tokens,
           augmented_messages,
           schema,
           llm_opts
         ) do
      response when is_struct(response) ->
        # Got response, try to extract content again
        new_content = extract_content_from_response(response)

        deserialize_loop(
          new_content,
          schema,
          client,
          model,
          temperature,
          max_tokens,
          messages,
          opts,
          adapter,
          attempt,
          max_retries
        )

      _ ->
        {:error, :llm_call_failed}
    end
  end

  defp parse_and_populate(content, schema, adapter, opts) do
    cleaned_content = ContentCleaner.clean(content)

    case Decoder.decode(cleaned_content, adapter, opts) do
      {:ok, parsed} when is_map(parsed) ->
        SchemaBinder.bind(parsed, schema, content)

      {:error, reason} ->
        {:error, {:json_parse_error, reason, content}}

      _ ->
        {:error, {:unexpected_parse_result, content}}
    end
  end

  # Extract content from response struct
  defp extract_content_from_response(%{chat_message: text}) when is_binary(text), do: text

  defp extract_content_from_response(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(Map.get(&1, :type) == :text || Map.get(&1, "type") == "text"))
    |> Enum.map(&(Map.get(&1, :text) || Map.get(&1, "text") || ""))
    |> Enum.join("\n")
  end

  defp extract_content_from_response(%{content: content}) when is_binary(content), do: content
  defp extract_content_from_response(_), do: ""

  # Get JSON adapter from application config
  defp get_json_adapter do
    Application.get_env(:normandy, :adapter, Poison)
  end
end
