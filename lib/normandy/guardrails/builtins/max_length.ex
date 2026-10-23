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

  alias Normandy.Guardrails.Builtins.Field

  @behaviour Normandy.Guardrails.Guard

  @impl true
  def check(value, opts) do
    limit = Keyword.fetch!(opts, :limit)
    field = Keyword.get(opts, :field)

    unless is_integer(limit) and limit > 0 do
      raise ArgumentError,
            "#{inspect(__MODULE__)} :limit must be a positive integer, got: #{inspect(limit)}"
    end

    case Field.string!(__MODULE__, value, field) do
      nil -> :ok
      string -> too_long(string, limit, field)
    end
  end

  defp too_long(string, limit, field) do
    if String.length(string) > limit do
      {:error,
       [
         %{
           guard: __MODULE__,
           path: Field.path(field),
           message: "must be at most #{limit} characters",
           constraint: :max_length,
           limit: limit
         }
       ]}
    else
      :ok
    end
  end
end
