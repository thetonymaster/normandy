defmodule NormandyTest.Components.BaseIOSchemaTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.BaseIOSchema

  describe "List impl" do
    test "to_json/1 returns the list verbatim" do
      blocks = [
        %{"type" => "text", "text" => "hi"},
        %{"type" => "image", "source" => %{"type" => "url", "url" => "https://x/y.png"}}
      ]

      assert BaseIOSchema.to_json(blocks) == blocks
    end

    test "to_json/1 returns [] for an empty list" do
      assert BaseIOSchema.to_json([]) == []
    end

    test "__str__/1 and __rich__/1 return strings" do
      assert is_binary(BaseIOSchema.__str__([1, 2, 3]))
      assert is_binary(BaseIOSchema.__rich__([1, 2, 3]))
    end

    test "get_schema/1 returns an empty map" do
      assert BaseIOSchema.get_schema([]) == %{}
      assert BaseIOSchema.get_schema([%{a: 1}]) == %{}
    end
  end

  describe "Any fallback regression" do
    test "to_json/1 returns \"\" for non-list, non-map, non-binary input" do
      assert BaseIOSchema.to_json(:atom_value) == ""
      assert BaseIOSchema.to_json(42) == ""
    end
  end

  describe "BitString impl regression" do
    test "to_json/1 returns the binary verbatim" do
      assert BaseIOSchema.to_json("hello") == "hello"
    end
  end

  describe "Map impl regression" do
    test "to_json/1 JSON-encodes the map" do
      adapter = Application.get_env(:normandy, :adapter, Poison)
      expected = adapter.encode!(%{a: 1})
      assert BaseIOSchema.to_json(%{a: 1}) == expected
    end
  end
end
