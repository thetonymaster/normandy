defmodule Normandy.LLM.Json.SchemaTranslator do
  @moduledoc """
  Translates a Normandy schema specification (`__schema__(:specification)`)
  into a JSON Schema suitable for Anthropic structured outputs (constrained
  decoding): string keys, recursive `additionalProperties: false`, only the
  supported keywords. Returns `{:incompatible, reason}` for schemas
  constrained decoding cannot express (open `:map` objects, runaway nesting),
  so the caller can fall back to the legacy path.
  """

  @max_depth 8

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
      |> Enum.map(fn {k, v} -> {to_string(k), node(v, depth + 1)} end)
      |> Map.new()

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

  defp node(%{type: type} = spec, _depth) do
    %{"type" => to_string(type)}
    |> with_description(spec)
    |> with_enum(spec)
  end

  defp node(_spec, _depth), do: throw({:incompatible, :unsupported_node})

  defp with_description(map, spec) do
    case Map.get(spec, :description) do
      desc when is_binary(desc) and desc != "" -> Map.put(map, "description", desc)
      _ -> map
    end
  end

  defp with_enum(map, spec) do
    case Map.get(spec, :enum) do
      enum when is_list(enum) -> Map.put(map, "enum", enum)
      _ -> map
    end
  end
end
