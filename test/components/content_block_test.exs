defmodule NormandyTest.Components.ContentBlockTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.ContentBlock.Text
  alias Normandy.Components.ContentBlock.Image
  alias Normandy.Components.ContentBlock.Document

  describe "Text" do
    test "new/1 builds a text block" do
      assert %Text{text: "hello"} = Text.new("hello")
    end

    test "to_claudio/1 emits a string-keyed text content block" do
      block = Text.new("What is in this image?")

      assert Text.to_claudio(block) == %{
               "type" => "text",
               "text" => "What is in this image?"
             }
    end
  end

  describe "Image" do
    test "new_base64/2 builds a base64-sourced image block" do
      assert %Image{source: :base64, data: "abc", media_type: "image/png", url: nil} =
               Image.new_base64("abc", "image/png")
    end

    test "new_url/1 builds a url-sourced image block" do
      assert %Image{source: :url, url: "https://e/i.jpg", data: nil, media_type: nil} =
               Image.new_url("https://e/i.jpg")
    end

    test "to_claudio/1 emits a base64 source block" do
      block = Image.new_base64("BASE64DATA", "image/jpeg")

      assert Image.to_claudio(block) == %{
               "type" => "image",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "image/jpeg",
                 "data" => "BASE64DATA"
               }
             }
    end

    test "to_claudio/1 emits a url source block" do
      block = Image.new_url("https://example.com/cat.png")

      assert Image.to_claudio(block) == %{
               "type" => "image",
               "source" => %{
                 "type" => "url",
                 "url" => "https://example.com/cat.png"
               }
             }
    end

    test "to_claudio/1 raises on base64 block with nil data" do
      bad = %Image{source: :base64, data: nil, media_type: "image/png"}

      assert_raise ArgumentError, ~r/invalid base64 image/i, fn -> Image.to_claudio(bad) end
    end

    test "to_claudio/1 raises on base64 block with nil media_type" do
      bad = %Image{source: :base64, data: "D", media_type: nil}

      assert_raise ArgumentError, ~r/invalid base64 image/i, fn -> Image.to_claudio(bad) end
    end

    test "to_claudio/1 raises on url block with nil url" do
      bad = %Image{source: :url, url: nil}

      assert_raise ArgumentError, ~r/invalid url image/i, fn -> Image.to_claudio(bad) end
    end

    test "to_claudio/1 raises on unknown source" do
      bad = %Image{source: :nope}

      assert_raise ArgumentError, ~r/unsupported image source/i, fn -> Image.to_claudio(bad) end
    end
  end

  describe "Document" do
    test "new_file/1 builds a file_id-sourced document block" do
      assert %Document{source: :file_id, file_id: "file_abc"} = Document.new_file("file_abc")
    end

    test "to_claudio/1 emits a file-sourced document block" do
      block = Document.new_file("file_abc123")

      assert Document.to_claudio(block) == %{
               "type" => "document",
               "source" => %{
                 "type" => "file",
                 "file_id" => "file_abc123"
               }
             }
    end

    test "to_claudio/1 raises on file_id-source block with nil file_id" do
      bad = %Document{source: :file_id, file_id: nil}

      assert_raise ArgumentError, ~r/invalid document/i, fn -> Document.to_claudio(bad) end
    end
  end

  describe "cache_control" do
    test "default constructor leaves cache_control nil (Text)" do
      assert %Text{cache_control: nil} = Text.new("hi")
    end

    test "default constructor leaves cache_control nil (Image base64)" do
      assert %Image{cache_control: nil} = Image.new_base64("D", "image/png")
    end

    test "default constructor leaves cache_control nil (Image url)" do
      assert %Image{cache_control: nil} = Image.new_url("https://e/i.png")
    end

    test "default constructor leaves cache_control nil (Document)" do
      assert %Document{cache_control: nil} = Document.new_file("file_x")
    end

    test "with_cache/1 sets ephemeral cache_control on Text" do
      block = Text.new("hi") |> Text.with_cache()

      assert %Text{cache_control: %{"type" => "ephemeral"}} = block
    end

    test "with_cache/1 sets ephemeral cache_control on Image" do
      block = Image.new_base64("D", "image/png") |> Image.with_cache()

      assert %Image{cache_control: %{"type" => "ephemeral"}} = block
    end

    test "with_cache/1 sets ephemeral cache_control on Document" do
      block = Document.new_file("file_x") |> Document.with_cache()

      assert %Document{cache_control: %{"type" => "ephemeral"}} = block
    end

    test "with_cache/2 accepts a custom map (string keys)" do
      block = Text.new("hi") |> Text.with_cache(%{"type" => "ephemeral", "ttl" => "1h"})

      assert %Text{cache_control: %{"type" => "ephemeral", "ttl" => "1h"}} = block
    end

    test "with_cache/2 accepts a custom map (atom keys), stringified at to_claudio/1" do
      block = Text.new("hi") |> Text.with_cache(%{type: :ephemeral, ttl: "1h"})

      # Stored as-given on the struct; serializer normalizes the keys.
      assert Text.to_claudio(block) == %{
               "type" => "text",
               "text" => "hi",
               "cache_control" => %{"type" => :ephemeral, "ttl" => "1h"}
             }
    end

    test "Text.to_claudio/1 emits cache_control when set" do
      block = Text.new("Cache up to here.") |> Text.with_cache()

      assert Text.to_claudio(block) == %{
               "type" => "text",
               "text" => "Cache up to here.",
               "cache_control" => %{"type" => "ephemeral"}
             }
    end

    test "Image.to_claudio/1 emits cache_control on base64 source" do
      block = Image.new_base64("D", "image/png") |> Image.with_cache()

      assert Image.to_claudio(block) == %{
               "type" => "image",
               "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "D"},
               "cache_control" => %{"type" => "ephemeral"}
             }
    end

    test "Image.to_claudio/1 emits cache_control on url source" do
      block = Image.new_url("https://e/i.png") |> Image.with_cache()

      assert Image.to_claudio(block) == %{
               "type" => "image",
               "source" => %{"type" => "url", "url" => "https://e/i.png"},
               "cache_control" => %{"type" => "ephemeral"}
             }
    end

    test "Document.to_claudio/1 emits cache_control" do
      block = Document.new_file("file_x") |> Document.with_cache()

      assert Document.to_claudio(block) == %{
               "type" => "document",
               "source" => %{"type" => "file", "file_id" => "file_x"},
               "cache_control" => %{"type" => "ephemeral"}
             }
    end

    test "to_claudio/1 omits cache_control key when nil" do
      assert Map.has_key?(Text.to_claudio(Text.new("hi")), "cache_control") == false

      assert Map.has_key?(
               Image.to_claudio(Image.new_base64("D", "image/png")),
               "cache_control"
             ) == false

      assert Map.has_key?(
               Document.to_claudio(Document.new_file("file_x")),
               "cache_control"
             ) == false
    end

    test "with_cache/2 + to_claudio/1 raises when cache_control is a struct" do
      # `%{} = cache_control` matches structs in Elixir, so without an
      # explicit `not is_struct/1` guard the helper would iterate the
      # struct's fields (including `__struct__`) into the cache payload.
      bad_block = Text.new("hi") |> Text.with_cache(%Date{year: 2026, month: 1, day: 1})

      assert_raise ArgumentError, ~r/cache_control must be a plain map/, fn ->
        Text.to_claudio(bad_block)
      end
    end

    test "with_cache/2 raises on atom/string key collision after normalization" do
      # Pathological but possible: passing both an atom and a string version
      # of the same key would silently collapse to whichever the map
      # iterator emitted last. Better to raise than to lose caller intent.
      block = Text.new("hi") |> Text.with_cache(%{:type => "ephemeral", "type" => "custom"})

      assert_raise ArgumentError, ~r/contains both an atom and string version/, fn ->
        Text.to_claudio(block)
      end
    end
  end
end
