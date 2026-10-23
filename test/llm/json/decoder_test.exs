defmodule Normandy.LLM.Json.DecoderTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.Decoder

  test "decodes valid JSON " do
    assert {:ok, %{"a" => 1}} = Decoder.decode(~s({"a": 1}), [])
  end

  test "returns the decode error for invalid JSON" do
    assert {:error, _reason} = Decoder.decode("not json", [])
  end

  test "a truncated string is the decode error" do
    truncated = ~s({"page_text": "hello\\n\\n\\n)
    assert {:error, _reason} = Decoder.decode(truncated, [])
  end

  test "rejects input larger than max_input_bytes with an explicit error" do
    big = "\"" <> String.duplicate("a", 50) <> "\""

    assert {:error, {:input_too_large, size, 10}} =
             Decoder.decode(big, max_input_bytes: 10)

    assert size > 10
  end

  test "uses a generous default limit that does not trip normal payloads" do
    assert {:ok, %{"a" => 1}} = Decoder.decode(~s({"a": 1}), [])
  end
end
