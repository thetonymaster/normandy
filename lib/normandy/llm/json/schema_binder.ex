defmodule Normandy.LLM.Json.SchemaBinder do
  @moduledoc """
  Binds a parsed JSON map to a Normandy schema: normalize field names, cast,
  validate required fields, and unwrap a one-level tool-use "arguments" envelope.
  """

  alias Normandy.Validate

  @spec bind(map(), struct(), binary()) :: {:ok, struct()} | {:error, term()}
  def bind(parsed, schema, content) when is_map(parsed) do
    permitted_fields = get_permitted_fields(schema)
    required_fields = get_required_fields(schema)
    outer = cast_map(parsed, schema, permitted_fields, required_fields, content)
    maybe_unwrap_arguments(outer, parsed, schema, permitted_fields, required_fields, content)
  end

  # Cast a map of params against the schema and return either a populated
  # struct or a validation error in the same shape as parse_and_populate/4.
  defp cast_map(params, schema, permitted_fields, required_fields, content) do
    normalized_params = normalize_field_names(params)

    changeset =
      schema
      |> Validate.cast(normalized_params, permitted_fields, [])
      |> Validate.validate_required(required_fields)

    case Validate.apply_action(changeset, :parse) do
      {:ok, validated_schema} -> {:ok, validated_schema}
      {:error, changeset} -> {:error, {:validation_error, changeset, content}}
    end
  end

  # Opportunistically retry the cast against `parsed["arguments"]` when the
  # outer payload looks like a tool-use envelope and the outer cast either
  # produced nothing or already failed. One level only — no recursion.
  #
  # Rules:
  #   * Outer succeeded with populated data → keep outer; don't unwrap.
  #   * No "arguments" map → keep outer (success or error).
  #   * Inner cast succeeds with populated data → return inner.
  #   * Inner cast succeeds with all-defaults → keep outer (the envelope is
  #     unrelated to this schema; preserve the existing shape).
  #   * Inner cast errors → propagate the error if the inner map carried any
  #     permitted key (the data was meant for us and is invalid); otherwise
  #     keep outer so unrelated envelopes don't manufacture new errors.
  defp maybe_unwrap_arguments(
         outer,
         parsed,
         schema,
         permitted_fields,
         required_fields,
         content
       ) do
    inner = Map.get(parsed, "arguments")
    should_try? = outer_eligible?(outer, schema, permitted_fields) and is_map(inner)

    if should_try? do
      inner_result = cast_map(inner, schema, permitted_fields, required_fields, content)
      resolve_inner(outer, inner_result, inner, schema, permitted_fields)
    else
      outer
    end
  end

  defp outer_eligible?({:ok, populated}, schema, permitted_fields),
    do: all_defaults?(populated, schema, permitted_fields)

  defp outer_eligible?({:error, _}, _schema, _permitted_fields), do: true

  defp resolve_inner(outer, {:ok, inner_schema}, _inner_map, schema, permitted_fields) do
    if all_defaults?(inner_schema, schema, permitted_fields),
      do: outer,
      else: {:ok, inner_schema}
  end

  defp resolve_inner(outer, {:error, _} = inner_error, inner_map, _schema, permitted_fields) do
    if inner_targets_schema?(inner_map, permitted_fields),
      do: inner_error,
      else: outer
  end

  # True when every permitted field on the populated struct still matches the
  # corresponding field on the input schema — i.e. the cast didn't change anything.
  defp all_defaults?(populated, schema, permitted_fields) do
    Enum.all?(permitted_fields, fn field ->
      Map.get(populated, field) == Map.get(schema, field)
    end)
  end

  # True when the inner map has at least one key that corresponds to a
  # permitted field (atom or string form). Used to decide whether an inner
  # cast error is the user's data being invalid (propagate) versus an
  # unrelated envelope (suppress).
  defp inner_targets_schema?(inner_map, permitted_fields) when is_map(inner_map) do
    # Match against normalized keys so aliased inputs (response/message/text ->
    # chat_message) are recognized as targeting the schema — the cast in
    # cast_map/5 normalizes too, so the targeting check must agree with it.
    inner_keys = inner_map |> normalize_field_names() |> Map.keys()

    Enum.any?(permitted_fields, fn field ->
      Enum.any?(inner_keys, fn key ->
        key == field or key == Atom.to_string(field)
      end)
    end)
  end

  # Normalize field names (response/message/text -> chat_message)
  defp normalize_field_names(parsed_map) when is_map(parsed_map) do
    Enum.reduce(parsed_map, %{}, fn {key, value}, acc ->
      normalized_key =
        case key do
          "response" -> "chat_message"
          "message" -> "chat_message"
          "text" -> "chat_message"
          other -> other
        end

      Map.put(acc, normalized_key, value)
    end)
  end

  # Get permitted fields from schema specification
  defp get_permitted_fields(schema) do
    schema.__struct__.__specification__()
    |> Map.keys()
  end

  # Get required fields from schema specification.
  # Prefer the dedicated `__schema__(:required)` entry produced by
  # Normandy.Schema; fall back to scanning `__specification__/0` for
  # any schema whose spec stores per-field metadata maps.
  defp get_required_fields(schema) do
    module = schema.__struct__

    cond do
      function_exported?(module, :__schema__, 1) ->
        case module.__schema__(:required) do
          fields when is_list(fields) -> fields
          _ -> required_from_specification(module)
        end

      true ->
        required_from_specification(module)
    end
  end

  defp required_from_specification(module) do
    module.__specification__()
    |> Enum.filter(fn {_key, field_spec} ->
      is_map(field_spec) && Map.get(field_spec, :required, false)
    end)
    |> Enum.map(fn {key, _} -> key end)
  end
end
