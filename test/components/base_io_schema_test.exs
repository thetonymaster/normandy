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

  describe "content with no implementation" do
    test "to_json/1 raises instead of sending an empty message" do
      assert_raise Protocol.UndefinedError, fn -> BaseIOSchema.to_json(:atom_value) end
      assert_raise Protocol.UndefinedError, fn -> BaseIOSchema.to_json(42) end
    end
  end

  describe "content blocks" do
    alias Normandy.Components.AgentMemory
    alias Normandy.Components.ContentBlock.{Image, Text}

    test "a single block is sent as a one-block list" do
      block = %Text{text: "hi"}
      assert BaseIOSchema.to_json(block) == [block]
    end

    test "a single image message survives history/1" do
      image = %Image{source: :url, url: "https://example.com/a.png"}

      assert [%{role: "user", content: [^image]}] =
               AgentMemory.new_memory()
               |> AgentMemory.add_message("user", image)
               |> AgentMemory.history()
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
