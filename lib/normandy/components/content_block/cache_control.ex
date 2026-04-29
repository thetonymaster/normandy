defmodule Normandy.Components.ContentBlock.CacheControl do
  @moduledoc false

  # Internal helper shared by ContentBlock.{Text,Image,Document}.to_claudio/1.
  # Anthropic's wire shape uses string keys; callers may pass atom keys for
  # ergonomics. We stringify the top level (`:type` -> `"type"`, `:ttl` ->
  # `"ttl"`) so the on-the-wire JSON never carries Elixir atoms.

  @spec maybe_attach(map(), map() | nil) :: map()
  def maybe_attach(block, nil), do: block

  def maybe_attach(block, %{} = cache_control) do
    Map.put(block, "cache_control", normalize_keys(cache_control))
  end

  @spec normalize_keys(map()) :: map()
  def normalize_keys(%{} = map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
