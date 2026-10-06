defmodule Normandy.LLM.Json.SchemaTranslator do
  @moduledoc """
  Translates a Normandy schema specification (`__schema__(:specification)`)
  into a JSON Schema suitable for Anthropic structured outputs (constrained
  decoding): string keys, recursive `additionalProperties: false`, only the
  supported keywords. Returns `{:incompatible, reason}` for schemas
  constrained decoding cannot express (open `:map` objects, runaway nesting),
  so the caller can fall back to the legacy path.

  Properties keep the declaration order recorded in `:property_order` (constrained
  decoding generates them in that order), as a `Jason.OrderedObject`. Constraints it
  cannot send (`pattern`, string lengths, numeric bounds, item counts, `uniqueItems`,
  unsupported formats) are stated at the end of the property's `description`; the
  answer is still validated against the full schema.
  """

  alias Normandy.Schema.Wire

  @max_depth 8

  # The string formats constrained decoding supports; any other format is left
  # out of the schema and stated in the description (format_note/1).
  @formats ~w(date-time time date duration email hostname uri ipv4 ipv6 uuid)

  @spec translate(map()) :: {:ok, map()} | {:incompatible, term()}
  def translate(spec) when is_map(spec) do
    {:ok, node(spec, 0)}
  catch
    {:incompatible, reason} -> {:incompatible, reason}
  end

  defp node(_spec, depth) when depth > @max_depth, do: throw({:incompatible, :too_deep})

  defp node(%{type: :object} = spec, depth) do
    props = Map.get(spec, :properties)

    if is_nil(props) or props == %{} do
      throw({:incompatible, {:open_object, Map.get(spec, :title)}})
    end

    translated =
      props
      |> property_entries(Map.get(spec, :property_order))
      |> Enum.map(fn {k, v} -> {to_string(k), node(v, depth + 1)} end)
      |> properties(Map.get(spec, :property_order))

    %{
      "type" => "object",
      "properties" => translated,
      "required" => spec |> Map.get(:required, []) |> Enum.map(&to_string/1),
      "additionalProperties" => false
    }
    |> with_description(spec)
  end

  defp node(%{type: :array} = spec, depth) do
    items = Map.get(spec, :items, %{type: :string})

    %{"type" => "array", "items" => node(items, depth + 1)}
    |> with_description(spec)
  end

  defp node(%{type: t} = spec, _depth)
       when t in [:integer, :float, :number, :boolean, :string] do
    scalar_type = if t == :float, do: "number", else: to_string(t)

    %{"type" => scalar_type}
    |> with_description(spec)
    |> with_enum(spec)
    |> with_format(spec)
  end

  defp node(%{type: other}, _depth),
    do: throw({:incompatible, {:unsupported_type, other}})

  defp node(_spec, _depth), do: throw({:incompatible, :unsupported_node})

  # Declaration order (Normandy.Schema's :property_order) is generation order under
  # constrained decoding (AX-17); a spec without it keeps a map.
  defp property_entries(props, nil), do: Map.to_list(props)
  defp property_entries(props, order), do: Wire.ordered_entries!(props, order)

  defp properties(entries, nil), do: Map.new(entries)
  defp properties(entries, _order), do: Jason.OrderedObject.new(entries)

  # The description, then each constraint constrained decoding cannot enforce, stated in
  # words (AX-18): the model still sees them, and Normandy validates them afterwards.
  defp with_description(map, spec) do
    description = Map.get(spec, :description)

    text =
      case Enum.reject(constraint_notes(spec), &is_nil/1) do
        [] -> if is_binary(description), do: description, else: ""
        notes -> Enum.join(Enum.reject([sentence(description) | notes], &is_nil/1), " ")
      end

    if text == "", do: map, else: Map.put(map, "description", text)
  end

  defp constraint_notes(spec) do
    [
      range_note(spec[:minLength], spec[:maxLength], "characters"),
      pattern_note(spec[:pattern]),
      format_note(spec[:format]),
      bound_note("Minimum", spec[:minimum]),
      bound_note("Maximum", spec[:maximum]),
      bound_note("Greater than", spec[:exclusiveMinimum]),
      bound_note("Less than", spec[:exclusiveMaximum]),
      range_note(spec[:minItems], spec[:maxItems], "items"),
      if(spec[:uniqueItems] == true, do: "Items must be unique.")
    ]
  end

  # A description followed by notes ends its own sentence.
  defp sentence(text) when is_binary(text) and text != "" do
    text = String.trim_trailing(text)
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  defp sentence(_text), do: nil

  defp range_note(nil, nil, _unit), do: nil
  defp range_note(same, same, unit), do: "Exactly #{same} #{unit}."
  defp range_note(min, nil, unit), do: "At least #{min} #{unit}."
  defp range_note(nil, max, unit), do: "At most #{max} #{unit}."
  defp range_note(min, max, unit), do: "Between #{min} and #{max} #{unit}."

  defp pattern_note(nil), do: nil
  defp pattern_note(%Regex{} = regex), do: pattern_note(Regex.source(regex))

  defp pattern_note(pattern) when is_binary(pattern),
    do: "Must match the regular expression #{pattern}."

  # A format with_format/2 sends is enforced; any other is stated.
  defp format_note(nil), do: nil

  defp format_note(format) do
    format = if is_atom(format), do: Atom.to_string(format), else: format
    if format in @formats, do: nil, else: "Format: #{format}."
  end

  defp bound_note(_label, nil), do: nil
  defp bound_note(label, value), do: "#{label} #{value}."

  defp with_format(map, spec) do
    format =
      case Map.get(spec, :format) do
        atom when is_atom(atom) and not is_nil(atom) -> Atom.to_string(atom)
        other -> other
      end

    if format in @formats, do: Map.put(map, "format", format), else: map
  end

  defp with_enum(map, spec) do
    case Map.get(spec, :enum) do
      enum when is_list(enum) -> Map.put(map, "enum", enum)
      _ -> map
    end
  end
end
