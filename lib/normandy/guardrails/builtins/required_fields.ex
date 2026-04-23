defmodule Normandy.Guardrails.Builtins.RequiredFields do
  @moduledoc """
  Rejects a struct or map when any of the named fields are `nil`.

  Intended for **output** guardrails: Normandy's `ValidationMiddleware` already
  enforces schema-level `required` constraints, but this guard lets callers
  assert on fields whose "must be populated" requirement is runtime (for
  example, a response schema where `result` is optional in the spec but must be
  present in this particular workflow).

  ## Options

  - `:fields` (required) — non-empty list of atoms.

  Emits one violation per missing field, each with `:path` set to `[field]`
  so existing error renderers show the field name.
  """

  @behaviour Normandy.Guardrails.Guard

  @impl true
  def check(value, opts) do
    fields = Keyword.fetch!(opts, :fields)

    unless is_list(fields) and fields != [] and Enum.all?(fields, &is_atom/1) do
      raise ArgumentError,
            "#{inspect(__MODULE__)} :fields must be a non-empty list of atoms, got: #{inspect(fields)}"
    end

    unless is_map(value) do
      raise ArgumentError,
            "#{inspect(__MODULE__)} expected a map or struct, got: #{inspect(value)}"
    end

    missing =
      Enum.filter(fields, fn field ->
        case Map.fetch(value, field) do
          {:ok, nil} -> true
          {:ok, _} -> false
          :error -> true
        end
      end)

    case missing do
      [] ->
        :ok

      missing_fields ->
        violations =
          Enum.map(missing_fields, fn field ->
            %{
              guard: __MODULE__,
              path: [field],
              message: "is required",
              constraint: :required_field
            }
          end)

        {:error, violations}
    end
  end
end
