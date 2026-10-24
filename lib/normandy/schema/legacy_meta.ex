defmodule Normandy.Schema.LegacyMeta do
  @moduledoc false
  # Schema structs written by 1.x and earlier 2.0 builds carry `__meta__:
  # %Normandy.Metadata{}`. The field and the module are gone, but stored terms still
  # hold them: Postgres and Redis decode with `binary_to_term(_, [:safe])`, which
  # refuses an atom nothing in the code names, so `Normandy.Metadata` stays named here
  # (as config_template.ex keeps `CredentialProvider.FromClient`). `strip/1` removes the
  # key from every struct in a loaded term, so it never reaches the model or the JSON.

  @legacy_module Normandy.Metadata

  @spec strip(term()) :: term()
  def strip(%mod{__meta__: %{__struct__: @legacy_module}} = struct) when is_atom(mod) do
    struct |> Map.delete(:__meta__) |> strip_fields()
  end

  def strip(%_{} = struct), do: strip_fields(struct)

  def strip(map) when is_map(map), do: :maps.map(fn _k, v -> strip(v) end, map)
  def strip(list) when is_list(list), do: strip_list(list)

  def strip(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> strip_list() |> List.to_tuple()

  def strip(other), do: other

  # Improper lists (term_to_binary can hold them) are walked cell by cell.
  defp strip_list([]), do: []
  defp strip_list([head | tail]), do: [strip(head) | strip_list(tail)]
  defp strip_list(other), do: strip(other)

  defp strip_fields(%_{} = struct) do
    :maps.map(fn _k, v -> strip(v) end, struct)
  end
end
