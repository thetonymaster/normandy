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
end
