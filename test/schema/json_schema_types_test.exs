defmodule Normandy.Schema.JsonSchemaTypesTest do
  use ExUnit.Case, async: true

  alias Normandy.Schema.Validator

  defmodule Code3 do
    @moduledoc false
    use Normandy.Type
    def type, do: :string
    def cast(v) when is_binary(v), do: {:ok, v}
    def cast(_), do: :error
    def dump(v), do: {:ok, v}
    def load(v), do: {:ok, v}
  end

  defmodule Kinds do
    @moduledoc false
    use Normandy.Schema

    io_schema "every non-primitive field type" do
      field(:meta, :map, description: "meta")
      field(:counts, {:map, :integer}, description: "counts")
      field(:anything, :any, description: "anything")
      field(:blob, :binary, description: "blob")
      field(:bits, :bitstring, description: "bits")
      field(:on, :date, description: "on")
      field(:at, :time, description: "at")
      field(:for, :duration, description: "for")
      field(:thing, :struct, description: "thing")
      field(:code, Code3, description: "code")
      field(:grid, {:array, {:array, :string}}, description: "grid")
      field(:ratios, {:array, :float}, description: "ratios")
    end
  end

  defp prop(name), do: Kinds.__schema__(:specification).properties[name]

  test ":map and :struct are JSON objects" do
    assert prop(:meta).type == :object
    assert prop(:thing).type == :object
  end

  test "{:map, inner} describes its values with additionalProperties" do
    assert prop(:counts).type == :object
    assert prop(:counts).additionalProperties == %{type: :integer}
  end

  test ":any has no type constraint" do
    refute Map.has_key?(prop(:anything), :type)
  end

  test ":binary and :bitstring are strings" do
    assert prop(:blob).type == :string
    assert prop(:bits).type == :string
  end

  test ":date, :time and :duration are strings with a format" do
    assert %{type: :string, format: "date"} = prop(:on)
    assert %{type: :string, format: "time"} = prop(:at)
    assert %{type: :string, format: "duration"} = prop(:for)
  end

  test "a custom Normandy.Type uses its type/0" do
    assert prop(:code).type == :string
  end

  test "nested arrays and float items get JSON item types" do
    assert prop(:grid).items == %{type: :array, items: %{type: :string}}
    assert prop(:ratios).items == %{type: :number}
  end

  test "the specification encodes to JSON" do
    assert {:ok, _json} = Jason.encode(Kinds.__schema__(:specification))
  end

  test "the Validator accepts Elixir values for the string-with-format types" do
    assert {:ok, _} =
             Validator.validate(Kinds, %{
               on: ~D[2026-10-01],
               at: ~T[10:00:00],
               for: Duration.new!(hour: 1),
               blob: "abc",
               meta: %{"a" => 1},
               thing: %URI{}
             })
  end

  test "the Validator still rejects a wrong value for those types" do
    assert {:error, _} = Validator.validate(Kinds, %{on: 42})
  end
end
