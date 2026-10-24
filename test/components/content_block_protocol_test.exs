defmodule Normandy.Components.ContentBlockProtocolTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.ContentBlock.{Document, Image, Protocol, Text}

  defmodule NotABlock do
    defstruct [:x]
  end

  test "every block answers to_claudio/1 like its own module" do
    for block <- [
          Text.new("hi") |> Text.with_cache(),
          Image.new_url("https://x/y.png"),
          Image.new_base64("QQ==", "image/png"),
          Document.new_file("file_1")
        ] do
      assert Protocol.to_claudio(block) == block.__struct__.to_claudio(block)
    end
  end

  test "estimate_tokens/1 and label/1" do
    assert Protocol.estimate_tokens(Text.new(String.duplicate("a", 40))) == 10
    assert Protocol.estimate_tokens(Image.new_url("u")) == 1600
    assert Protocol.estimate_tokens(Document.new_file("f")) == 3000
    assert Protocol.label(Text.new("hello")) == "hello"
    assert Protocol.label(Image.new_url("u")) == "[image]"
    assert Protocol.label(Document.new_file("f")) == "[document]"
  end

  test "a struct that is not a block has no implementation" do
    assert Protocol.impl_for(%NotABlock{}) == nil
    assert Protocol.impl_for(%{"type" => "text"}) == nil
  end
end
