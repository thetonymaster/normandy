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
    assert %{"type" => "object"} = hd(body["tools"])["input_schema"]
    assert %{"format" => %{"type" => "json_schema"}} = body["output_config"]
    assert body["output_config"]["format"]["schema"]["required"] == ["a"]
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

  test "a per-call header set on the Req client survives with_betas and retry (telemetry)" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    plug = fn conn ->
      attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(test_pid, {:headers, attempt, conn.req_headers})

      if attempt == 1 do
        conn
        |> Plug.Conn.put_status(529)
        |> Req.Test.json(%{"error" => %{"type" => "overloaded_error", "message" => "x"}})
      else
        Req.Test.json(conn, %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end
    end

    client =
      Req.new(
        base_url: "http://claudio.test",
        plug: plug,
        retry: fn _req, resp -> match?(%Req.Response{status: 529}, resp) end,
        retry_delay: 1,
        max_retries: 2
      )
      |> Req.Request.put_header("traceparent", "00-abc-def-01")

    request =
      Request.new("claude-opus-5-5")
      |> Request.set_max_tokens(64)
      |> Request.add_message(:user, "hi")
      |> Request.set_output_format(%{"type" => "object"})

    assert {:ok, _} = Claudio.Messages.create(client, request)

    for attempt <- [1, 2] do
      assert_receive {:headers, ^attempt, headers}
      assert {"traceparent", "00-abc-def-01"} in headers
    end
  end
end
