defmodule Normandy.LLM.Json.DecoderTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.Decoder

  test "decodes valid JSON via the adapter" do
    assert {:ok, %{"a" => 1}} = Decoder.decode(~s({"a": 1}), Normandy.JSON, [])
  end

  test "returns the adapter error for invalid JSON" do
    assert {:error, _reason} = Decoder.decode("not json", Normandy.JSON, [])
  end

  test "a truncated string is the adapter error" do
    truncated = ~s({"page_text": "hello\\n\\n\\n)
    assert {:error, _reason} = Decoder.decode(truncated, Normandy.JSON, [])
  end

  test "rejects input larger than max_input_bytes with an explicit error" do
    big = "\"" <> String.duplicate("a", 50) <> "\""

    assert {:error, {:input_too_large, size, 10}} =
             Decoder.decode(big, Normandy.JSON, max_input_bytes: 10)

    assert size > 10
  end

  test "uses a generous default limit that does not trip normal payloads" do
    assert {:ok, %{"a" => 1}} = Decoder.decode(~s({"a": 1}), Normandy.JSON, [])
  end
end
