defmodule Normandy.LLM.ClaudioAdapterTaskBudgetWireTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter

  @messages [%Message{role: "user", content: "hi"}]

  defp reply(text) do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5-5",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
    }
  end

  # Each request body goes to the test process; replies come from `texts` in order.
  defp stub_replies(name, texts) do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      Req.Test.json(conn, reply(Enum.at(texts, n, List.last(texts))))
    end)
  end

  defp client(name, extra) do
    %ClaudioAdapter{
      api_key: "k",
      options:
        Map.merge(
          %{task_budget: 64_000, req_options: [plug: {Req.Test, name}, retry: false]},
          extra
        )
    }
  end

  defp converse(client, opts) do
    Normandy.Agents.Model.converse(
      client,
      "claude-opus-5-5",
      nil,
      1024,
      @messages,
      %BaseAgentOutputSchema{},
      opts
    )
  end

  test "structured path: remaining reaches output_config.task_budget" do
    stub_replies(__MODULE__.Structured, [~s({"chat_message": "ok"})])
    converse(client(__MODULE__.Structured, %{}), task_budget_remaining: 40_000)

    assert_received {:body, body}

    assert body["output_config"]["task_budget"] ==
             %{"type" => "tokens", "total" => 64_000, "remaining" => 40_000}
  end

  test "legacy path: remaining reaches the request, and the JSON retry call too" do
    stub_replies(__MODULE__.Legacy, ["not json", ~s({"chat_message": "ok"})])

    converse(client(__MODULE__.Legacy, %{structured_outputs: false}),
      task_budget_remaining: 40_000
    )

    assert_received {:body, first}
    assert_received {:body, retry}
    assert first["output_config"]["task_budget"]["remaining"] == 40_000
    assert retry["output_config"]["task_budget"]["remaining"] == 40_000
  end

  test "no remaining in opts: only the total goes out" do
    stub_replies(__MODULE__.TotalOnly, [~s({"chat_message": "ok"})])
    converse(client(__MODULE__.TotalOnly, %{}), [])

    assert_received {:body, body}
    assert body["output_config"]["task_budget"] == %{"type" => "tokens", "total" => 64_000}
  end

  test "stream_converse: remaining reaches the request body" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        400,
        ~s({"type":"error","error":{"type":"invalid_request_error","message":"captured"}})
      )
    end)

    client = %ClaudioAdapter{
      api_key: "k",
      base_url: "http://localhost:#{bypass.port}/",
      options: %{task_budget: 64_000}
    }

    # stream_converse/7 is an impl function, not a protocol callback.
    Normandy.Agents.Model.impl_for(client).stream_converse(
      client,
      "claude-opus-5-5",
      nil,
      1024,
      @messages,
      %BaseAgentOutputSchema{},
      task_budget_remaining: 40_000
    )

    assert_received {:body, body}
    assert body["output_config"]["task_budget"]["remaining"] == 40_000
  end
end
