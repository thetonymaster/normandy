defmodule Normandy.Guardrails.Builtins.ForbiddenSubstrings do
  @moduledoc """
  Rejects strings containing any of the configured forbidden substrings.

  ## Options

  - `:terms` (required) — list of strings to block. Must be a non-empty list.
  - `:field` (optional) — atom naming a field to extract from a struct or map
    before checking. If omitted, the value itself must be a string.
  - `:case_sensitive` (optional, default `false`) — when `false`, matching is
    done after downcasing both the value and the terms.

  Returns one violation per matched term (not just the first), so callers can
  see the full set of offending phrases.
  """

  @behaviour Normandy.Guardrails.Guard

  @impl true
  def check(value, opts) do
    terms = Keyword.fetch!(opts, :terms)
    field = Keyword.get(opts, :field)
    case_sensitive = Keyword.get(opts, :case_sensitive, false)

    unless is_list(terms) and terms != [] and Enum.all?(terms, &is_binary/1) do
      raise ArgumentError,
            "#{inspect(__MODULE__)} :terms must be a non-empty list of strings, got: #{inspect(terms)}"
    end

    case extract(value, field) do
      nil ->
        :ok

      string when is_binary(string) ->
        haystack = if case_sensitive, do: string, else: String.downcase(string)
        needles = if case_sensitive, do: terms, else: Enum.map(terms, &String.downcase/1)

        matched =
          terms
          |> Enum.zip(needles)
          |> Enum.filter(fn {_original, needle} -> String.contains?(haystack, needle) end)
          |> Enum.map(fn {original, _needle} -> original end)

        case matched do
          [] ->
            :ok

          terms ->
            path = if field, do: [field], else: []

            violations =
              Enum.map(terms, fn term ->
                %{
                  guard: __MODULE__,
                  path: path,
                  message: "must not contain forbidden term #{inspect(term)}",
                  constraint: :forbidden_substring,
                  term: term
                }
              end)

            {:error, violations}
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
