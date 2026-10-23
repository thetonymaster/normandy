defmodule Normandy.LLM.Json.Decoder do
  @moduledoc false
  # Decodes a cleaned JSON string via the configured adapter, behind a
  # `:max_input_bytes` guard.

  @default_max_input_bytes 10_000_000

  @spec decode(binary(), module(), keyword()) :: {:ok, map()} | {:error, term()}
  def decode(content, adapter, opts) when is_binary(content) do
    case Keyword.get(opts, :max_input_bytes, @default_max_input_bytes) do
      limit when is_integer(limit) and limit > 0 ->
        size = byte_size(content)

        if size > limit do
          {:error, {:input_too_large, size, limit}}
        else
          decode_inner(content, adapter)
        end

      invalid ->
        {:error, {:invalid_max_input_bytes, invalid}}
    end
  end

  defp decode_inner(cleaned_content, adapter) do
    adapter.decode(cleaned_content)
  end
end
