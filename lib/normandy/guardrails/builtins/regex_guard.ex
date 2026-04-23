defmodule Normandy.Guardrails.Builtins.RegexGuard do
  @moduledoc """
  Rejects (or requires) regex matches against a string.

  Useful for simple PII patterns (SSN, credit-card-like digit runs) in `:deny`
  mode, or for ensuring a response contains a required marker in `:require`
  mode.

  ## Options

  - `:patterns` (required) — list of compiled `Regex.t()` values. Must be
    non-empty.
  - `:mode` (optional, default `:deny`) — `:deny` rejects when any pattern
    matches; `:require` rejects when no pattern matches.
  - `:field` (optional) — atom naming a field to extract from a struct or map
    before checking.

  Empty `:deny` against a nil/missing field is a no-op. Empty `:require` against
  a nil/missing field *is* a violation — the required pattern couldn't possibly
  be present in missing text.
  """

  @behaviour Normandy.Guardrails.Guard

  @impl true
  def check(value, opts) do
    patterns = Keyword.fetch!(opts, :patterns)
    field = Keyword.get(opts, :field)
    mode = Keyword.get(opts, :mode, :deny)

    unless is_list(patterns) and patterns != [] and Enum.all?(patterns, &is_struct(&1, Regex)) do
      raise ArgumentError,
            "#{inspect(__MODULE__)} :patterns must be a non-empty list of Regex, got: #{inspect(patterns)}"
    end

    unless mode in [:deny, :require] do
      raise ArgumentError,
            "#{inspect(__MODULE__)} :mode must be :deny or :require, got: #{inspect(mode)}"
    end

    check_value(extract(value, field), patterns, mode, field)
  end

  defp check_value(nil, patterns, :require, field) do
    path = if field, do: [field], else: []

    {:error,
     [
       %{
         guard: __MODULE__,
         path: path,
         message: "must match one of #{length(patterns)} required patterns",
         constraint: :regex_require
       }
     ]}
  end

  defp check_value(nil, _patterns, :deny, _field), do: :ok

  defp check_value(string, patterns, :deny, field) when is_binary(string) do
    matched = Enum.filter(patterns, &Regex.match?(&1, string))

    case matched do
      [] ->
        :ok

      matched_patterns ->
        path = if field, do: [field], else: []

        violations =
          Enum.map(matched_patterns, fn pattern ->
            %{
              guard: __MODULE__,
              path: path,
              message: "must not match pattern #{inspect(pattern)}",
              constraint: :regex_deny,
              pattern: pattern
            }
          end)

        {:error, violations}
    end
  end

  defp check_value(string, patterns, :require, field) when is_binary(string) do
    if Enum.any?(patterns, &Regex.match?(&1, string)) do
      :ok
    else
      path = if field, do: [field], else: []

      {:error,
       [
         %{
           guard: __MODULE__,
           path: path,
           message: "must match one of #{length(patterns)} required patterns",
           constraint: :regex_require
         }
       ]}
    end
  end

  defp check_value(other, _patterns, _mode, field) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} expected a string#{field_suffix(field)}, got: #{inspect(other)}"
  end

  defp extract(value, nil), do: value
  defp extract(value, field) when is_map(value), do: Map.get(value, field)
  defp extract(_value, _field), do: nil

  defp field_suffix(nil), do: ""
  defp field_suffix(field), do: " at field #{inspect(field)}"
end
