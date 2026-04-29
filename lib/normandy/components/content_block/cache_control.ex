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
    # Stringifying atom keys can collide with existing string keys
    # (`%{type: "x", "type" => "y"}` would silently lose one entry under
    # `Map.new/2`). Detect collisions during the reduce and raise — caller
    # intent is unrecoverable from a collapsed map.
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      key = if is_atom(k), do: Atom.to_string(k), else: k

      if Map.has_key?(acc, key) do
        raise ArgumentError,
              "Normandy.Components.ContentBlock.CacheControl: cache_control map " <>
                "contains both an atom and string version of the same key after " <>
                "normalization (#{inspect(key)}). Pick one form."
      end

      Map.put(acc, key, v)
    end)
  end
end
