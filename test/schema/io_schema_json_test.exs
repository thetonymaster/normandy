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
    @derive {Poison.Encoder, only: [:shown]}

    io_schema "derived encoder" do
      field(:shown, :string, description: "s")
      field(:hidden, :string, description: "h")
    end
  end

  test "to_json leaves out the internal __meta__ field" do
    json = BaseIOSchema.to_json(%Plain{verdict: "approve"})

    assert Poison.decode!(json) == %{"verdict" => "approve"}
  end

  test "a derived encoder still decides the fields" do
    json = BaseIOSchema.to_json(%Derived{shown: "a", hidden: "b"})

    assert Poison.decode!(json) == %{"shown" => "a"}
  end
end
