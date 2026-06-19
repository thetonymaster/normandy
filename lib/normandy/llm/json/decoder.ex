defmodule Normandy.LLM.Json.Decoder do
  @moduledoc """
  Decodes a cleaned JSON string via the configured adapter, with an optional
  one-shot truncated-string recovery pass (see Json.Scanner).
  """

  alias Normandy.LLM.Json.Scanner

  @spec decode(binary(), module(), keyword()) :: {:ok, map()} | {:error, term()}
  def decode(cleaned_content, adapter, opts) do
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
end
