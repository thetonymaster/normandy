defmodule Normandy.LLM.ClaudioRequestCapabilitiesTest do
  @moduledoc "What the 2.0 waves need Claudio's request builder to express."
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request

  defp body(request), do: request |> Request.to_map() |> Jason.encode!() |> Jason.decode!()

  test "tools and output_config.format in one request (Task 5.1)" do
    body =
      Request.new("claude-opus-5-5")
      |> Request.set_max_tokens(64)
      |> Request.add_tool(%{name: "t", description: "d", input_schema: %{"type" => "object"}})
      |> Request.set_output_format(%{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}},
        "required" => ["a"],
        "additionalProperties" => false
      })
      |> body()

    assert [%{"name" => "t"}] = body["tools"]
    assert %{"format" => %{"type" => "json_schema"}} = body["output_config"]
  end

  test "an assistant message replayed with raw content blocks (Task 5.3)" do
    blocks = [
      %{"type" => "thinking", "thinking" => "x", "signature" => "s"},
      %{
        "type" => "mcp_tool_use",
        "id" => "m1",
        "name" => "n",
        "server_name" => "srv",
        "input" => %{}
      },
      %{"type" => "text", "text" => "a"},
      %{"type" => "text", "text" => "b"}
    ]

    body =
      Request.new("claude-opus-5-5")
      |> Request.set_max_tokens(64)
      |> Request.add_message(:user, "hi")
      |> Request.add_message(:assistant, blocks)
      |> body()

    assert [_, %{"role" => "assistant", "content" => ^blocks}] = body["messages"]
  end
end
