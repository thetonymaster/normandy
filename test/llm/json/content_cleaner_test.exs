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
end
