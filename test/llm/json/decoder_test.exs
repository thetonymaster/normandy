defmodule Normandy.LLM.Json.DecoderTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.Decoder

  test "decodes valid JSON via the adapter" do
    assert {:ok, %{"a" => 1}} = Decoder.decode(~s({"a": 1}), Poison, [])
  end

  test "returns the adapter error for invalid JSON" do
    assert {:error, _reason} = Decoder.decode("not json", Poison, [])
  end

  test "recovers a truncated top-level string when opt is enabled" do
    truncated = ~s({"page_text": "hello\\n\\n\\n)

    assert {:ok, %{"page_text" => "hello"}} =
             Decoder.decode(truncated, Poison, recover_truncated_strings: true)
  end

  test "without the opt, truncated content returns the adapter error" do
    truncated = ~s({"page_text": "hello\\n\\n\\n)
    assert {:error, _reason} = Decoder.decode(truncated, Poison, [])
  end

  test "rejects input larger than max_input_bytes with an explicit error" do
    big = "\"" <> String.duplicate("a", 50) <> "\""

    assert {:error, {:input_too_large, size, 10}} =
             Decoder.decode(big, Poison, max_input_bytes: 10)

    assert size > 10
  end

  test "uses a generous default limit that does not trip normal payloads" do
    assert {:ok, %{"a" => 1}} = Decoder.decode(~s({"a": 1}), Poison, [])
  end
end
