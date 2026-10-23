defmodule Normandy.Schema.MetadataTest do
  use ExUnit.Case, async: true

  defmodule Doc do
    use Normandy.Schema

    schema do
      field(:name, :string)
    end
  end

  describe "%Normandy.Metadata{}" do
    test "keeps the state and the schema, nothing else" do
      assert %Normandy.Metadata{} |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               [:schema, :state]
    end

    test "a built struct's meta names the schema" do
      assert %Normandy.Metadata{state: :built, schema: Doc} = struct(Doc).__meta__
      assert inspect(struct(Doc).__meta__) == "#Normandy.Metadata<:built>"
    end
  end
end
