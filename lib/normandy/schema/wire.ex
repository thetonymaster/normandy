defmodule Normandy.Schema.Wire do
  @moduledoc """
  A JSON Schema as the model sees it.

  `Normandy.Schema` keeps a field's declaration order in the specification under
  `:property_order` (a plain map, so `spec[:properties][name]` keeps working). Elixir maps
  do not keep key order, so a specification encoded as it is lists its properties in an
  order unrelated to the declaration. The model reads (and constrained decoding
  generates) properties in the order they are sent, so declaration order is generation
  order: declare `reasoning` before `answer` to have the model reason first.

  `encodable/1` returns the specification ready for `Normandy.JSON`:

    * every `properties` map that has a `:property_order` becomes a
      `Jason.OrderedObject` in that order; `:property_order` itself is removed;
    * `"$schema"` and `"title"` (atom or string keys) are removed from every schema node;
      a property *named* `title` is kept;
    * it recurses into `properties`, `items`, `additionalProperties`, `not`, `if`,
      `then`, `else`, `anyOf`, `oneOf`, `allOf` and `prefixItems`.

  A node without `:property_order` (a hand-written or MCP schema) keeps its `properties`
  as a map. Normandy calls it where a schema leaves for the model: tool `input_schema`
  (`Normandy.Tools.Toolset.to_tool_schemas/1`), the system prompt's `# OUTPUT SCHEMA`
  block and the JSON retry feedback. `__schema__(:specification)` and an io_schema's
  `get_json_schema/0` return the specification unchanged.

  A custom `config :normandy, :adapter` receives `Jason.OrderedObject` structs from these
  call sites; Jason encodes them in order.
  """

  @dropped [:"$schema", "$schema", :title, "title"]
  @schema_keys [:items, "items", :additionalProperties, "additionalProperties", :not, "not"] ++
                 [:if, "if", :then, "then", :else, "else"]
  @schema_list_keys [:anyOf, "anyOf", :oneOf, "oneOf", :allOf, "allOf"] ++
                      [:prefixItems, "prefixItems"]

  @doc "The schema with ordered properties and without `$schema` and `title`."
  @spec encodable(term()) :: term()
  def encodable(%{} = schema) when not is_struct(schema) do
    {order, schema} = Map.pop(schema, :property_order)

    schema
    |> Map.drop(@dropped)
    |> Map.new(fn {key, value} -> {key, child(key, value, order)} end)
  end

  def encodable(other), do: other

  @doc false
  # The `properties` entries in `order`, which must name each property exactly once.
  @spec ordered_entries!(map(), [atom() | String.t()]) :: [{atom() | String.t(), term()}]
  def ordered_entries!(properties, order) when is_map(properties) and is_list(order) do
    if Enum.sort(order) != Enum.sort(Map.keys(properties)) do
      raise ArgumentError,
            "expected :property_order to name each property exactly once, got " <>
              "#{inspect(order)} for the properties #{inspect(Enum.sort(Map.keys(properties)))}"
    end

    Enum.map(order, &{&1, Map.fetch!(properties, &1)})
  end

  defp child(key, %{} = properties, order)
       when key in [:properties, "properties"] and not is_struct(properties) do
    walked = Map.new(properties, fn {name, schema} -> {name, encodable(schema)} end)

    case order do
      nil -> walked
      order -> walked |> ordered_entries!(order) |> Jason.OrderedObject.new()
    end
  end

  defp child(key, schema, _order) when key in @schema_keys, do: encodable(schema)

  defp child(key, schemas, _order) when key in @schema_list_keys and is_list(schemas),
    do: Enum.map(schemas, &encodable/1)

  defp child(_key, value, _order), do: value
end
