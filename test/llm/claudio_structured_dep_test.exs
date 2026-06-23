defmodule Normandy.LLM.ClaudioStructuredDepTest do
  use ExUnit.Case, async: true

  test "Claudio exposes set_output_format/2 for structured outputs" do
    # function_exported?/3 returns false for a not-yet-loaded module; force-load
    # so the check is deterministic regardless of async test ordering (seed).
    Code.ensure_loaded!(Claudio.Messages.Request)
    assert function_exported?(Claudio.Messages.Request, :set_output_format, 2)
  end

  test "set_output_format sets a json_schema output_config.format on the request" do
    req =
      Claudio.Messages.Request.new("claude-haiku-4-5")
      |> Claudio.Messages.Request.set_output_format(%{
        "type" => "object",
        "properties" => %{"chat_message" => %{"type" => "string"}},
        "required" => ["chat_message"],
        "additionalProperties" => false
      })

    assert %{"format" => %{"type" => "json_schema", "schema" => %{"type" => "object"}}} =
             req.output_config
  end
end
