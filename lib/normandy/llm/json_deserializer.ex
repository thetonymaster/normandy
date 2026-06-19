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

  alias Normandy.Components.Message
  alias Normandy.LLM.Json.ContentCleaner
  alias Normandy.LLM.Json.Scanner
  alias Normandy.Validate

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
    error_message = build_error_feedback(error, failed_content, schema)

    # Augment system prompt with error feedback
    augmented_messages = augment_messages_with_error(messages, error_message)

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

  # Parse JSON and validate using Normandy.Validate
  defp parse_and_populate(content, schema, adapter, opts) do
    # Clean content (remove markdown code fences, etc.)
    cleaned_content = ContentCleaner.clean(content)

    case decode_with_optional_recovery(cleaned_content, adapter, opts) do
      {:ok, parsed} when is_map(parsed) ->
        permitted_fields = get_permitted_fields(schema)
        required_fields = get_required_fields(schema)

        outer = cast_map(parsed, schema, permitted_fields, required_fields, content)

        maybe_unwrap_arguments(
          outer,
          parsed,
          schema,
          permitted_fields,
          required_fields,
          content
        )

      {:error, reason} ->
        # JSON parse failed
        {:error, {:json_parse_error, reason, content}}

      _ ->
        {:error, {:unexpected_parse_result, content}}
    end
  end

  # Decode JSON, optionally retrying once via truncated-string recovery.
  #
  # When :recover_truncated_strings is true AND the cleaned content looks like a
  # single top-level object AND the strict decode fails AND the failure mode is
  # "unclosed top-level string at depth 1 with a \n-escape runaway tail" (as
  # determined by recover_truncated_string/1), we synthesize a closing quote and
  # balance the brace stack, then re-decode once. On success we emit a recovery
  # telemetry event. On any failure we return the original adapter error so the
  # caller's existing {:json_parse_error, _, _} contract is preserved.
  defp decode_with_optional_recovery(cleaned_content, adapter, opts) do
    case adapter.decode(cleaned_content) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, _reason} = original_error ->
        with true <- Keyword.get(opts, :recover_truncated_strings, false),
             true <- top_level_object?(cleaned_content),
             {:ok, recovered} <- Scanner.recover_truncated_string(cleaned_content),
             {:ok, parsed} <- adapter.decode(recovered) do
          emit_recovery_telemetry(byte_size(cleaned_content), byte_size(recovered))
          {:ok, parsed}
        else
          _ -> original_error
        end
    end
  end

  defp top_level_object?(content) when is_binary(content) do
    case String.trim_leading(content) do
      "{" <> _ -> true
      _ -> false
    end
  end

  defp emit_recovery_telemetry(byte_size_before, byte_size_after) do
    :telemetry.execute(
      [:normandy, :json_deserializer, :recovery],
      %{recovered: 1},
      %{
        strategy: :truncated_string,
        byte_size_before: byte_size_before,
        byte_size_after: byte_size_after
      }
    )
  end

  # Cast a map of params against the schema and return either a populated
  # struct or a validation error in the same shape as parse_and_populate/4.
  defp cast_map(params, schema, permitted_fields, required_fields, content) do
    normalized_params = normalize_field_names(params)

    changeset =
      schema
      |> Validate.cast(normalized_params, permitted_fields)
      |> Validate.validate_required(required_fields)

    case Validate.apply_action(changeset, :parse) do
      {:ok, validated_schema} -> {:ok, validated_schema}
      {:error, changeset} -> {:error, {:validation_error, changeset, content}}
    end
  end

  # Opportunistically retry the cast against `parsed["arguments"]` when the
  # outer payload looks like a tool-use envelope and the outer cast either
  # produced nothing or already failed. One level only — no recursion.
  #
  # Rules:
  #   * Outer succeeded with populated data → keep outer; don't unwrap.
  #   * No "arguments" map → keep outer (success or error).
  #   * Inner cast succeeds with populated data → return inner.
  #   * Inner cast succeeds with all-defaults → keep outer (the envelope is
  #     unrelated to this schema; preserve the existing shape).
  #   * Inner cast errors → propagate the error if the inner map carried any
  #     permitted key (the data was meant for us and is invalid); otherwise
  #     keep outer so unrelated envelopes don't manufacture new errors.
  defp maybe_unwrap_arguments(
         outer,
         parsed,
         schema,
         permitted_fields,
         required_fields,
         content
       ) do
    inner = Map.get(parsed, "arguments")
    should_try? = outer_eligible?(outer, schema, permitted_fields) and is_map(inner)

    if should_try? do
      inner_result = cast_map(inner, schema, permitted_fields, required_fields, content)
      resolve_inner(outer, inner_result, inner, schema, permitted_fields)
    else
      outer
    end
  end

  defp outer_eligible?({:ok, populated}, schema, permitted_fields),
    do: all_defaults?(populated, schema, permitted_fields)

  defp outer_eligible?({:error, _}, _schema, _permitted_fields), do: true

  defp resolve_inner(outer, {:ok, inner_schema}, _inner_map, schema, permitted_fields) do
    if all_defaults?(inner_schema, schema, permitted_fields),
      do: outer,
      else: {:ok, inner_schema}
  end

  defp resolve_inner(outer, {:error, _} = inner_error, inner_map, _schema, permitted_fields) do
    if inner_targets_schema?(inner_map, permitted_fields),
      do: inner_error,
      else: outer
  end

  # True when every permitted field on the populated struct still matches the
  # corresponding field on the input schema — i.e. the cast didn't change anything.
  defp all_defaults?(populated, schema, permitted_fields) do
    Enum.all?(permitted_fields, fn field ->
      Map.get(populated, field) == Map.get(schema, field)
    end)
  end

  # True when the inner map has at least one key that corresponds to a
  # permitted field (atom or string form). Used to decide whether an inner
  # cast error is the user's data being invalid (propagate) versus an
  # unrelated envelope (suppress).
  defp inner_targets_schema?(inner_map, permitted_fields) when is_map(inner_map) do
    inner_keys = Map.keys(inner_map)

    Enum.any?(permitted_fields, fn field ->
      Enum.any?(inner_keys, fn key ->
        key == field or key == Atom.to_string(field)
      end)
    end)
  end

  # Normalize field names (response/message/text -> chat_message)
  defp normalize_field_names(parsed_map) when is_map(parsed_map) do
    Enum.reduce(parsed_map, %{}, fn {key, value}, acc ->
      normalized_key =
        case key do
          "response" -> "chat_message"
          "message" -> "chat_message"
          "text" -> "chat_message"
          other -> other
        end

      Map.put(acc, normalized_key, value)
    end)
  end

  # Get permitted fields from schema specification
  defp get_permitted_fields(schema) do
    schema.__struct__.__specification__()
    |> Map.keys()
  end

  # Get required fields from schema specification.
  # Prefer the dedicated `__schema__(:required)` entry produced by
  # Normandy.Schema; fall back to scanning `__specification__/0` for
  # any schema whose spec stores per-field metadata maps.
  defp get_required_fields(schema) do
    module = schema.__struct__

    cond do
      function_exported?(module, :__schema__, 1) ->
        case module.__schema__(:required) do
          fields when is_list(fields) -> fields
          _ -> required_from_specification(module)
        end

      true ->
        required_from_specification(module)
    end
  end

  defp required_from_specification(module) do
    module.__specification__()
    |> Enum.filter(fn {_key, field_spec} ->
      is_map(field_spec) && Map.get(field_spec, :required, false)
    end)
    |> Enum.map(fn {key, _} -> key end)
  end

  # Build error feedback message for LLM
  defp build_error_feedback(
         {:validation_error, changeset, content},
         _failed_content,
         schema
       ) do
    schema_json = Poison.encode!(schema.__struct__.__specification__(), pretty: true)

    # Extract detailed field-level errors using traverse_errors
    error_details =
      Validate.traverse_errors(changeset, fn {msg, opts} ->
        # Format error message with interpolated values
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)
      |> format_validation_errors()

    """
    # JSON VALIDATION ERROR

    Your previous response was valid JSON, but failed validation.

    ## Validation Errors
    #{error_details}

    ## Your Previous Response
    ```json
    #{String.slice(content, 0, 500)}#{if String.length(content) > 500, do: "...", else: ""}
    ```

    ## Required Schema
    ```json
    #{schema_json}
    ```

    ## Instructions for Correction

    1. You MUST provide ALL required fields
    2. Ensure field types match the schema (string, integer, etc.)
    3. Ensure field values meet validation requirements
    4. Do NOT wrap your JSON in markdown code blocks
    5. Do NOT add any text before or after the JSON

    Please provide a corrected JSON response addressing all validation errors above.
    """
  end

  defp build_error_feedback(
         {:json_parse_error, reason, content},
         _failed_content,
         schema
       ) do
    schema_json = Poison.encode!(schema.__struct__.__specification__(), pretty: true)

    """
    # JSON DESERIALIZATION ERROR

    Your previous response could not be parsed as valid JSON.

    ## Error Details
    #{format_json_error(reason)}

    ## Your Previous Response
    ```
    #{String.slice(content, 0, 500)}#{if String.length(content) > 500, do: "...", else: ""}
    ```

    ## Required Schema
    ```json
    #{schema_json}
    ```

    ## Instructions for Correction

    1. You MUST respond with ONLY valid JSON
    2. Do NOT wrap your JSON in markdown code blocks
    3. Do NOT add any text before or after the JSON
    4. Ensure all field names exactly match the schema
    5. Ensure proper JSON escaping (quotes, newlines, etc.)
    6. Do NOT nest the response in extra JSON objects

    Example of CORRECT response:
    {"chat_message": "This is my response"}

    Example of INCORRECT responses:
    - {"chat_message": "{\\"chat_message\\": \\"nested\\"}"}  ❌ Double nesting
    - ```json\\n{"chat_message": "response"}\\n```  ❌ Code blocks
    - Some text {"chat_message": "response"}  ❌ Extra text

    Please provide a corrected JSON response now.
    """
  end

  defp build_error_feedback(reason, content, _schema) do
    """
    # RESPONSE FORMAT ERROR

    Error: #{inspect(reason)}

    Your previous response:
    ```
    #{String.slice(content, 0, 500)}
    ```

    Please provide a valid JSON response.
    """
  end

  # Format validation errors for LLM feedback
  defp format_validation_errors(error_map) when is_map(error_map) do
    error_map
    |> Enum.map(fn {field, errors} ->
      formatted_errors = errors |> Enum.map(&"  - #{&1}") |> Enum.join("\n")
      "• Field `#{field}`:\n#{formatted_errors}"
    end)
    |> Enum.join("\n\n")
  end

  # Format JSON error for human readability
  defp format_json_error({:invalid, reason, position}) do
    "Invalid JSON at position #{position}: #{reason}"
  end

  defp format_json_error({:invalid, reason}) do
    "Invalid JSON: #{reason}"
  end

  defp format_json_error(reason) do
    "JSON parsing failed: #{inspect(reason)}"
  end

  # Augment messages with error feedback
  defp augment_messages_with_error(messages, error_message) do
    # Find system message and append error feedback
    Enum.map(messages, fn msg ->
      case msg do
        %Message{role: "system", content: content} = message ->
          %Message{message | content: content <> "\n\n" <> error_message}

        other ->
          other
      end
    end)
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
