defmodule Normandy.LLM.Json.RetryFeedback do
  @moduledoc """
  Builds the corrective feedback appended to the system prompt on a JSON
  retry, and augments the message history with it.
  """

  alias Normandy.Components.Message
  alias Normandy.Validate

  @spec build(term(), binary(), struct(), module()) :: String.t()
  def build(
        {:validation_error, changeset, content},
        _failed_content,
        schema,
        adapter
      ) do
    schema_json = adapter.encode!(schema.__struct__.__specification__(), pretty: true)

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

  def build(
        {:json_parse_error, reason, content},
        _failed_content,
        schema,
        adapter
      ) do
    schema_json = adapter.encode!(schema.__struct__.__specification__(), pretty: true)

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

  def build(reason, content, _schema, _adapter) do
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

  @spec augment_messages([Message.t()], String.t()) :: [Message.t()]
  def augment_messages(messages, feedback) do
    # Find system message and append error feedback
    Enum.map(messages, fn msg ->
      case msg do
        %Message{role: "system", content: content} = message ->
          %Message{message | content: content <> "\n\n" <> feedback}

        other ->
          other
      end
    end)
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
end
