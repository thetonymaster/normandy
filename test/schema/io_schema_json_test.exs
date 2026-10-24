defmodule Normandy.Schema.IoSchemaJsonTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.BaseIOSchema

  defmodule Plain do
    use Normandy.Schema

    io_schema "no derive" do
      field(:verdict, :string, description: "v")
    end
  end

  defmodule Derived do
    use Normandy.Schema
    @derive {Jason.Encoder, only: [:shown]}

    io_schema "derived encoder" do
      field(:shown, :string, description: "s")
      field(:hidden, :string, description: "h")
    end
  end

  test "a struct has no __meta__ key and its JSON has none" do
    refute Map.has_key?(%Plain{}, :__meta__)
    json = BaseIOSchema.to_json(%Plain{verdict: "approve"})
    refute json =~ "__meta__"

    assert Jason.decode!(json) == %{"verdict" => "approve"}
  end

  test "a derived encoder still decides the fields" do
    json = BaseIOSchema.to_json(%Derived{shown: "a", hidden: "b"})

    assert Jason.decode!(json) == %{"shown" => "a"}
  end
end
