defmodule Normandy.SchemaTest do
  use ExUnit.Case, async: true

  defmodule Schema do
    use Normandy.Schema

    schema do
      field(:name, :string, default: "eric", description: "name of the user")
      field(:password, :string, redact: true)
      field(:count, :integer)
      field(:map, {:map, :string}, default: nil)
      field(:array, {:array, :string})
    end
  end

  test "schema fields" do
    assert Schema.__schema__(:fields) == [:name, :password, :count, :map, :array]
  end

  test "types metadata" do
    assert Schema.__schema__(:type, :name) == :string
    assert Schema.__schema__(:type, :array) == {:array, :string}
  end

  test "specification metadata" do
    assert Schema.__specification__() == %{
             name: :string,
             array: {:array, :string},
             count: :integer,
             map: {:map, :string},
             password: :string
           }
  end

  test "default" do
    assert %Schema{}.name == "eric"
    assert %Schema{}.map == nil
  end

  test "specification" do
    assert Schema.__schema__(:specification) == %{
             type: "object",
             title: "Schema",
             "$schema": "https://json-schema.org/draft/2020-12/schema",
             properties: %{
              name: %{
                description: "name of the user",
                type: :string,
              },
              password: %{
                description: "",
                type: :string,
              },
              count: %{
                description: "",
                type: :integer,
              },
              map: %{
                description: "",
                type: :object,
              },
              array: %{
                description: "",
                type: :array,
                items: %{
                  type: :string
                }
              }
             }
           }
  end
end
