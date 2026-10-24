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

  defmodule Boom do
    defstruct []

    defimpl Jason.Encoder do
      def encode(_, _), do: raise("cannot encode metadata")
    end
  end

  defmodule Foreign do
    defstruct [:id, __meta__: %Boom{}]
  end

  defmodule Holder do
    use Normandy.Schema

    io_schema "holds anything" do
      field(:user, :any)
    end
  end

  test "to_json leaves out the __meta__ of a nested foreign struct whose encoder raises" do
    json = BaseIOSchema.to_json(%Holder{user: %Foreign{id: 1}})

    assert Jason.decode!(json) == %{"user" => %{"id" => 1}}
  end

  test "to_json leaves out a nested legacy Normandy.Metadata" do
    legacy = %{__struct__: Normandy.Metadata, state: :built, schema: Holder}
    user = %Foreign{id: 2} |> Map.put(:__meta__, legacy)

    json = BaseIOSchema.to_json(%Holder{user: user})

    refute json =~ "__meta__"
  end
end
