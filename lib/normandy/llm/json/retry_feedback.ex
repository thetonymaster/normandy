defmodule Normandy.LLM.Json.RetryFeedback do
  @moduledoc """
  Builds the corrective feedback sent as a user message on a JSON
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
    schema_json = adapter.encode!(Normandy.Schema.json_schema(schema), pretty: true)

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

    Respond with a corrected JSON object that fixes the errors above: include
    every required field, with types and values that satisfy the schema.
    """
  end

  def build(
        {:json_parse_error, reason, content},
        _failed_content,
        schema,
        adapter
      ) do
    parse_feedback(
      "JSON DESERIALIZATION ERROR",
      "Your previous response could not be parsed as valid JSON.",
      format_json_error(reason),
      content,
      schema,
      adapter
    )
  end

  # Any other failure (an answer over the size limit, JSON that is not an object) gets
  # the parse-error template with a plain description. The reason is an Elixir term,
  # never text for the model, so it is not shown.
  def build(reason, content, schema, adapter) do
    parse_feedback(
      "RESPONSE FORMAT ERROR",
      "Your previous response could not be used as the answer.",
      describe_failure(reason),
      content,
      schema,
      adapter
    )
  end

  defp parse_feedback(heading, summary, details, content, schema, adapter) do
    schema_json = adapter.encode!(Normandy.Schema.json_schema(schema), pretty: true)

    """
    # #{heading}

    #{summary}

    ## Error Details
    #{details}

    ## Your Previous Response
    ```
    #{String.slice(content, 0, 500)}#{if String.length(content) > 500, do: "...", else: ""}
    ```

    ## Required Schema
    ```json
    #{schema_json}
    ```

    Respond with a single JSON object whose field names match the schema exactly,
    with strings properly escaped. Put the field values at the top level of that
    object rather than encoding another JSON document inside a string field.
    """
  end

  defp describe_failure({:input_too_large, size, limit}),
    do: "The response is #{size} bytes; the limit is #{limit} bytes. Give a shorter answer."

  defp describe_failure({:unexpected_parse_result, _content}),
    do: "The response is valid JSON, but not a JSON object."

  defp describe_failure(_reason), do: "The response does not match the required format."

  @spec augment_messages([Message.t()], String.t()) :: [Message.t()]
  # The feedback quotes the model's own failed output, so it goes in a user
  # message after the conversation, never into the system prompt (where a
  # prompt-injected response could steer the retry). That also works for a
  # block-list system prompt and for a conversation without one.
  def augment_messages(messages, feedback) do
    turn_id =
      case List.last(messages) do
        %Message{turn_id: turn_id} -> turn_id
        _ -> nil
      end

    messages ++ [%Message{turn_id: turn_id, role: "user", content: feedback}]
  end

  # Format validation errors for LLM feedback
  defp format_validation_errors(error_map) when is_map(error_map) do
    error_map
    |> Enum.map_join("\n\n", fn {field, errors} ->
      formatted_errors = errors |> Enum.map_join("\n", &"  - #{&1}")
      "• Field `#{field}`:\n#{formatted_errors}"
    end)
  end

  # Format JSON error for human readability
  defp format_json_error({:invalid, reason, position}) do
    "Invalid JSON at position #{position}: #{reason}"
  end

  defp format_json_error({:invalid, reason}) do
    "Invalid JSON: #{reason}"
  end

  defp format_json_error(%{__exception__: true} = exception),
    do: "Invalid JSON: #{Exception.message(exception)}"

  defp format_json_error(_reason), do: "The response is not valid JSON."
end
