defmodule Normandy.LLM.RequestResponseTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.Message
  alias Normandy.LLM.{Request, Response}

  test "a request needs model, messages and max_tokens" do
    assert_raise ArgumentError, ~r/the following keys must also be given.*:max_tokens/, fn ->
      struct!(Request, model: "m", messages: [])
    end
  end

  test "a request defaults the optional fields" do
    request = %Request{
      model: "m",
      messages: [%Message{role: "user", content: "hi"}],
      max_tokens: 10
    }

    assert %Request{
             system: nil,
             response_model: nil,
             temperature: nil,
             tools: [],
             mcp_servers: nil,
             task_budget_remaining: nil
           } = request
  end

  test "a response needs content and defaults the rest" do
    assert %Response{content: "x", stop_reason: nil, usage: nil, meta: %{}} =
             %Response{content: "x"}

    assert_raise ArgumentError, fn -> struct!(Response, []) end
  end
end
