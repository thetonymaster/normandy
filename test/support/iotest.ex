defmodule Normandy.IOTest do
  use Normandy.Schema
  @derive {Poison.Encoder, only: [:test_field]}

  schema do
    field(:test_field, :string, default: "test_value")
  end

  defimpl Normandy.Components.BaseIOSchema, for: __MODULE__ do
    def __str__(str), do: Poison.encode!(str)
    def __rich__(str), do: Poison.encode!(str, pretty: true)
    def schema(_), do: __MODULE__.schema(:specification)
    def to_json(str), do: Poison.encode!(str)
  end
end
