defmodule Normandy.LLM.ClaudioAdapterJsonRetryTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema, Model}
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLM.Response

  @moduletag :capture_log

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

  # Replies come from `texts` in order (the last one repeats); each request is
  # reported to the test process.
  defp stub_replies(name, texts) do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(name, fn conn ->
      send(test_pid, :request)
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      Req.Test.json(conn, reply(Enum.at(texts, n, List.last(texts))))
    end)
  end

  defp client(name) do
    %ClaudioAdapter{
      api_key: "k",
      options: %{structured_outputs: false, req_options: [plug: {Req.Test, name}, retry: false]}
    }
  end

  defp converse(client, opts) do
    Model.converse(
      client,
      %Normandy.LLM.Request{
        model: "claude-opus-5-5",
        max_tokens: 1024,
        messages: [%Message{role: "user", content: "hi"}],
        response_model: %BaseAgentOutputSchema{}
      },
      opts
    )
  end

  defp requests do
    receive do
      :request -> 1 + requests()
    after
      0 -> 0
    end
  end

  test "json_retries sets how many retries a parse failure gets" do
    stub_replies(__MODULE__.Zero, ["not json"])
    converse(client(__MODULE__.Zero), json_retries: 0)
    assert requests() == 1

    stub_replies(__MODULE__.One, ["not json"])
    converse(client(__MODULE__.One), json_retries: 1)
    assert requests() == 2
  end

  test "without json_retries a parse failure gets 2 retries" do
    stub_replies(__MODULE__.Default, ["not json"])
    converse(client(__MODULE__.Default), [])
    assert requests() == 3
  end

  test "the retries' token usage is added to the reported usage" do
    stub_replies(__MODULE__.Usage, ["not json", ~s({"chat_message": "ok"})])

    assert {:ok, %Response{content: %BaseAgentOutputSchema{chat_message: "ok"}, usage: usage}} =
             converse(client(__MODULE__.Usage), [])

    assert (usage[:input_tokens] || usage["input_tokens"]) == 6
    assert (usage[:output_tokens] || usage["output_tokens"]) == 4
  end

  describe "BaseAgent JSON retry settings" do
    test "enable_json_retry: false means no retries" do
      stub_replies(__MODULE__.Disabled, ["not json"])

      agent =
        BaseAgent.init(%{
          client: client(__MODULE__.Disabled),
          model: "claude-opus-5-5",
          enable_json_retry: false
        })

      BaseAgent.run!(agent, "hi")
      assert requests() == 1
    end

    test "json_retry_max_attempts sets the number of retries, and retry is on by default" do
      stub_replies(__MODULE__.Attempts, ["not json"])

      agent =
        BaseAgent.init(%{
          client: client(__MODULE__.Attempts),
          model: "claude-opus-5-5",
          json_retry_max_attempts: 1
        })

      assert agent.enable_json_retry
      BaseAgent.run!(agent, "hi")
      assert requests() == 2
    end
  end
end
