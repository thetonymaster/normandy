defmodule Normandy.LLM.ParseFailure do
  @moduledoc false
  # What an adapter does when the model's output does not parse into the response
  # schema, under the `:on_parse_failure` policy. Shared by every adapter.

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.LLMError

  require Logger

  @doc """
  The policy for a call: a per-call `:on_parse_failure`, then
  `client.options[:on_parse_failure]`, then the `:normandy` app env, then `:fallback`.
  """
  @spec policy(map()) :: :fallback | :error
  def policy(context) do
    client_options =
      case Map.get(context, :client) do
        %{options: options} when is_map(options) -> options
        _ -> %{}
      end

    policy =
      Map.get(context, :on_parse_failure) ||
        Map.get(client_options, :on_parse_failure) ||
        Application.get_env(:normandy, :on_parse_failure, :fallback)

    if policy in [:fallback, :error] do
      policy
    else
      raise ArgumentError,
            ":on_parse_failure must be :fallback or :error; " <>
              "got #{Describe.type_of(policy)}"
    end
  end

  @doc """
  `:error` returns an `:invalid_output` error. `:fallback` puts the raw text in the
  schema's `:chat_message`; a schema without that field has nothing to fall back
  to, so it gets the error too rather than an empty struct presented as success.
  """
  @spec apply(struct(), term(), term(), map()) :: struct() | {:error, LLMError.t()}
  def apply(schema, content, reason, context) do
    fallback? = Map.has_key?(schema, :chat_message)

    case policy(context) do
      :fallback when fallback? and is_binary(content) ->
        report_fallback(reason, content, "falling back to raw text")
        Map.put(schema, :chat_message, content)

      :fallback when fallback? ->
        report_fallback(reason, content, "returning schema unchanged")
        schema

      :fallback ->
        invalid_output(
          reason,
          "model output did not match the schema, which has no " <>
            ":chat_message to fall back to"
        )

      :error ->
        invalid_output(reason, "model output did not match the schema")
    end
  end

  defp invalid_output(reason, detail),
    do:
      {:error,
       LLMError.new(type: :invalid_output, retryable?: false, detail: detail, reason: reason)}

  # The model output can hold user data and be megabytes long, so the log and
  # telemetry carry the failure's tag and the output's size, not the output.
  defp report_fallback(reason, content, action) do
    tag = reason_tag(reason)
    bytes = if is_binary(content), do: byte_size(content), else: 0

    Logger.warning(
      "JSON parse failed; #{action}. reason=#{inspect(tag)}, model output: #{bytes} bytes"
    )

    :telemetry.execute([:normandy, :json_deserializer, :fallback], %{count: 1}, %{
      reason: tag,
      content_bytes: bytes
    })
  end

  defp reason_tag(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(_reason), do: :unknown
end
