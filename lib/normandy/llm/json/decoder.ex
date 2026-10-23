defmodule Normandy.LLM.Json.Decoder do
  @moduledoc false
  # Decodes a cleaned JSON string through `Normandy.JSON`, behind a
  # `:max_input_bytes` guard.

  @default_max_input_bytes 10_000_000

  @doc false
  # `opts[:max_input_bytes]` (default 10_000_000): larger content is
  # `{:error, {:input_too_large, size, limit}}` before any parse.
  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def decode(content, opts) when is_binary(content) do
    case Keyword.get(opts, :max_input_bytes, @default_max_input_bytes) do
      limit when is_integer(limit) and limit > 0 ->
        size = byte_size(content)

        if size > limit do
          {:error, {:input_too_large, size, limit}}
        else
          Normandy.JSON.decode(content)
        end

      invalid ->
        {:error, {:invalid_max_input_bytes, invalid}}
    end
  end
end
