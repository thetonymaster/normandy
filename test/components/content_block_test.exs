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
  end
end
