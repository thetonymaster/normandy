defmodule Normandy.Components.ToolResultTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.{BaseIOSchema, ToolResult}

  defp content(output) do
    [%{content: content}] = BaseIOSchema.to_json(%ToolResult{tool_call_id: "t", output: output})
    content
  end

  test "list output is sent as JSON, not Elixir inspect syntax" do
    assert content([%{"title" => "a"}, %{"title" => "b"}]) == ~s([{"title":"a"},{"title":"b"}])
  end

  test "map output is sent as JSON" do
    assert content(%{"ok" => true}) == ~s({"ok":true})
  end

  test "text and numbers are sent as text" do
    assert content("done") == "done"
    assert content(3) == "3"
  end
end
