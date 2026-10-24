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

  alias Normandy.Guardrails.Builtins.Field

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

    case Field.string!(__MODULE__, value, field) do
      nil -> :ok
      string -> violations(string, terms, case_sensitive, Field.path(field))
    end
  end

  defp violations(string, terms, case_sensitive, path) do
    haystack = if case_sensitive, do: string, else: String.downcase(string)

    matched =
      Enum.filter(terms, fn term ->
        String.contains?(haystack, if(case_sensitive, do: term, else: String.downcase(term)))
      end)

    case matched do
      [] -> :ok
      _ -> {:error, Enum.map(matched, &violation(&1, path))}
    end
  end

  defp violation(term, path) do
    %{
      guard: __MODULE__,
      path: path,
      message: "must not contain forbidden term #{inspect(term)}",
      constraint: :forbidden_substring,
      term: term
    }
  end
end
