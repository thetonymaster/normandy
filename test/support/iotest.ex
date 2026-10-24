defmodule NormandyTest.IOTest do
  @moduledoc false
  use Normandy.Schema
  @derive {Jason.Encoder, only: [:test_field]}

  schema do
    field(:test_field, :string, default: "test_value")
  end

  defimpl Normandy.Components.BaseIOSchema, for: __MODULE__ do
    def get_schema(_), do: NormandyTest.IOTest.__schema__(:specification)
    def to_json(str), do: Normandy.JSON.encode!(str)
  end
end
