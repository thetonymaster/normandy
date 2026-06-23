defmodule Normandy.LLM.Json.ScannerTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.Scanner

  test "recovers an unclosed top-level string truncated at a \\n runaway" do
    truncated = ~s({"page_text": "hello world\\n\\n\\n)
    assert {:ok, recovered} = Scanner.recover_truncated_string(truncated)
    assert {:ok, %{"page_text" => "hello world"}} = Poison.decode(recovered)
  end

  test "recovers an immediately-truncated empty top-level string" do
    assert {:ok, recovered} = Scanner.recover_truncated_string(~s({"page_text": "))
    assert {:ok, %{"page_text" => ""}} = Poison.decode(recovered)
  end

  test "declines recovery for truncation inside a nested object" do
    assert :error = Scanner.recover_truncated_string(~s({"a": {"b": "oops\\n\\n))
  end
end
