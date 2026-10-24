defmodule Normandy.LLM.Json.Decoder do
  @moduledoc false
  # Decodes a cleaned JSON string through `Normandy.JSON`, behind a
  # `:max_input_bytes` guard.

  @default_max_input_bytes 10_000_000

  @doc false
  # `opts[:max_input_bytes]` (default 10_000_000): larger content is
  # `{:error, {:input_too_large, size, limit}}` before any parse.
  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def decode(content, opts) when is_binary(content),
    do: guarded(content, opts, &Normandy.JSON.decode/1)

  @doc false
  # decode/2, returning every object in the value as a string-keyed map, in the order
  # its `{` appears in the text (a parent before the objects inside it): the objects a
  # region holds, from one decode. Linear in the value's size: each plain map is built
  # once, from its children's.
  @spec decode_maps(binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def decode_maps(content, opts) when is_binary(content) do
    with {:ok, value} <- guarded(content, opts, &Normandy.JSON.decode_ordered/1) do
      {_plain, maps} = plain(value, [])
      {:ok, maps}
    end
  end

  defp guarded(content, opts, decode) do
    case Keyword.get(opts, :max_input_bytes, @default_max_input_bytes) do
      limit when is_integer(limit) and limit > 0 ->
        size = byte_size(content)

        if size > limit do
          {:error, {:input_too_large, size, limit}}
        else
          decode.(content)
        end

      invalid ->
        {:error, {:invalid_max_input_bytes, invalid}}
    end
  end

  # {plain value, maps}: `maps` is `acc` with the value's objects pushed in reverse text
  # order, so the list reads in text order. Children go right to left, the object
  # itself last.
  defp plain(%Jason.OrderedObject{values: pairs}, acc) do
    {plain_pairs, acc} =
      pairs
      |> Enum.reverse()
      |> Enum.reduce({[], acc}, fn {key, value}, {plain_pairs, acc} ->
        {plain_value, acc} = plain(value, acc)
        {[{key, plain_value} | plain_pairs], acc}
      end)

    map = Map.new(plain_pairs)
    {map, [map | acc]}
  end

  defp plain(list, acc) when is_list(list) do
    list
    |> Enum.reverse()
    |> Enum.reduce({[], acc}, fn value, {plain_values, acc} ->
      {plain_value, acc} = plain(value, acc)
      {[plain_value | plain_values], acc}
    end)
  end

  defp plain(scalar, acc), do: {scalar, acc}
end
