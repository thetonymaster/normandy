defmodule Normandy.LLM.Json.ContentCleanerTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.ContentCleaner

  test "strips a leading ```json fence and trailing fence" do
    assert ~s({"a": 1}) =
             ContentCleaner.clean("```json\n{\"a\": 1}\n```")
  end

  test "trims surrounding whitespace" do
    assert ~s({"a": 1}) = ContentCleaner.clean("   {\"a\": 1}   ")
  end

  test "passes non-binary content through unchanged" do
    assert %{a: 1} = ContentCleaner.clean(%{a: 1})
  end

  test "extracts a balanced object embedded in prose" do
    input = ~s(Here's the JSON:\n{"a": 1}\nHope that helps!)
    assert {:ok, ~s({"a": 1})} = ContentCleaner.extract_balanced(input)
  end

  test "ignores braces inside strings when balancing" do
    input = ~s(text {"a": "}{"} more)
    assert {:ok, ~s({"a": "}{"})} = ContentCleaner.extract_balanced(input)
  end

  test "returns :error when no balanced object is present" do
    assert :error = ContentCleaner.extract_balanced("no json here")
  end

  test "extract_balanced/2 returns the region and the byte offset it started at" do
    input = ~s(prefix {"a": 1} suffix)
    assert {:ok, ~s({"a": 1}), 7} = ContentCleaner.extract_balanced(input, 0)
  end

  test "extract_balanced/2 finds the next region at or after the given offset" do
    input = ~s({"a": 1} then {"b": 2})
    # Start scanning past the first object's opener.
    assert {:ok, ~s({"b": 2}), 14} = ContentCleaner.extract_balanced(input, 1)
  end

  test "skips an unbalanced opener to find a later balanced region" do
    input = ~s(oops {unclosed and then {"a": 1})
    assert {:ok, ~s({"a": 1})} = ContentCleaner.extract_balanced(input)
  end
end
