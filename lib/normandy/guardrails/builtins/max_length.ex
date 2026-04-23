defmodule Normandy.Guardrails.Builtins.MaxLength do
  @moduledoc """
  Rejects values whose string length exceeds `:limit`.

  ## Options

  - `:limit` (required) — positive integer, maximum length in graphemes.
  - `:field` (optional) — atom naming a field to extract from a struct or map
    before checking. If omitted, the value itself must be a string.

  If the configured field is missing or `nil` the guard is a no-op (nothing to
  check). If the resolved value is not a string, the guard raises
  `ArgumentError` — a string-length guard applied to a non-string is a
  configuration bug, not a runtime violation.
  """

  @behaviour Normandy.Guardrails.Guard

  @impl true
  def check(value, opts) do
    limit = Keyword.fetch!(opts, :limit)
    field = Keyword.get(opts, :field)

    unless is_integer(limit) and limit > 0 do
      raise ArgumentError,
            "#{inspect(__MODULE__)} :limit must be a positive integer, got: #{inspect(limit)}"
    end

    case extract(value, field) do
      nil ->
        :ok

      string when is_binary(string) ->
        if String.length(string) > limit do
          path = if field, do: [field], else: []

          {:error,
           [
             %{
               guard: __MODULE__,
               path: path,
               message: "must be at most #{limit} characters",
               constraint: :max_length,
               limit: limit
             }
           ]}
        else
          :ok
        end

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} expected a string#{field_suffix(field)}, got: #{inspect(other)}"
    end
  end

  defp extract(value, nil), do: value
  defp extract(value, field) when is_map(value), do: Map.get(value, field)
  defp extract(_value, _field), do: nil

  defp field_suffix(nil), do: ""
  defp field_suffix(field), do: " at field #{inspect(field)}"
end
