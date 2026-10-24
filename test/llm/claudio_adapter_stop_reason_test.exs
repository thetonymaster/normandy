defmodule Normandy.LLM.ClaudioAdapterStopReasonTest do
  @moduledoc """
  AX-10: a response that stopped at max_tokens or refusal is never parsed, re-asked or
  turned into chat_message text; Normandy.LLM.Call makes it the error.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Model
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLM.{Request, Response}
  alias Normandy.LLMError
  alias Normandy.Test.FakeTool

  defmodule Decision do
    use Normandy.Schema

    io_schema "A decision" do
      field(:action, :string, required: true)
    end
  end

  # Every request body goes to the test process; every reply is cut off.
  defp stub(name, stop_reason) do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5-5",
        "content" => [%{"type" => "text", "text" => ~s({"action": "appr)}],
        "stop_reason" => stop_reason,
        "usage" => %{"input_tokens" => 3, "output_tokens" => 64}
      })
    end)
  end

  defp agent(name, options) do
    BaseAgent.init(%{
      client: %ClaudioAdapter{
        api_key: "k",
        options: Map.merge(%{req_options: [plug: {Req.Test, name}, retry: false]}, options)
      },
      model: "claude-opus-5-5",
      output_schema: %Decision{}
    })
  end

  test "structured outputs: max_tokens is the error, with one request and the usage" do
    stub(__MODULE__.Structured, "max_tokens")

    assert {:error, %LLMError{type: :max_tokens, usage_counts: %{output_tokens: 64}}} =
             BaseAgent.run(agent(__MODULE__.Structured, %{}), "decide")

    assert_received {:body, %{"output_config" => %{"format" => _}}}
    refute_received {:body, _}
  end

  test "legacy path: max_tokens is the error, with no JSON retry" do
    stub(__MODULE__.Legacy, "max_tokens")

    assert {:error, %LLMError{type: :max_tokens}} =
             BaseAgent.run(agent(__MODULE__.Legacy, %{structured_outputs: false}), "decide")

    assert_received {:body, _}
    refute_received {:body, _}
  end

  test "refusal under on_parse_failure: :fallback never lands in chat_message" do
    stub(__MODULE__.Refusal, "refusal")

    assert {:error, %LLMError{type: :refusal}} =
             BaseAgent.run(agent(__MODULE__.Refusal, %{on_parse_failure: :fallback}), "decide")
  end

  test "model_context_window_exceeded is the :max_tokens error" do
    stub(__MODULE__.Window, "model_context_window_exceeded")

    assert {:error,
            %LLMError{
              type: :max_tokens,
              reason: {:stop_reason, :model_context_window_exceeded}
            }} = BaseAgent.run(agent(__MODULE__.Window, %{}), "decide")
  end

  test "a JSON retry cut off at max_tokens is the error, with both calls' usage" do
    test_pid = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__.Retry, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      n = Agent.get_and_update(calls, &{&1, &1 + 1})

      {text, stop, output} =
        if n == 0,
          do: {"not json", "end_turn", 5},
          else: {~s({"action": "ap), "max_tokens", 64}

      Req.Test.json(conn, %{
        "id" => "msg_#{n}",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5-5",
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => stop,
        "usage" => %{"input_tokens" => 3, "output_tokens" => output}
      })
    end)

    assert {:error, %LLMError{type: :max_tokens, usage_counts: %{output_tokens: 69}}} =
             BaseAgent.run(agent(__MODULE__.Retry, %{structured_outputs: false}), "decide")

    assert_received {:body, _first}
    assert_received {:body, _retry}
    refute_received {:body, _}
  end

  # Task 5.1 routes a tool-loop call with output_format to the structured path; its
  # incomplete clause covers that call too: no tool call or text is kept from it.
  test "a tool-loop call with output_format cut off at max_tokens comes back empty" do
    test_pid = self()

    Req.Test.stub(__MODULE__.ToolLoop, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-5-5",
        "content" => [
          %{"type" => "text", "text" => "Checking"},
          %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}
        ],
        "stop_reason" => "max_tokens",
        "usage" => %{"input_tokens" => 3, "output_tokens" => 64}
      })
    end)

    client = %ClaudioAdapter{
      api_key: "k",
      options: %{req_options: [plug: {Req.Test, __MODULE__.ToolLoop}, retry: false]}
    }

    request = %Request{
      model: "claude-opus-5-5",
      max_tokens: 64,
      messages: [%Message{role: "user", content: "decide"}],
      tools: [%{name: "weather", description: "w", input_schema: %{type: "object"}}],
      response_model: %ToolCallResponse{},
      output_format: %Decision{}
    }

    assert {:ok, %Response{content: %ToolCallResponse{} = content, stop_reason: :max_tokens}} =
             Model.converse(client, request, [])

    assert content == %ToolCallResponse{}
    assert_received {:body, %{"output_config" => %{"format" => _}, "tools" => [_]}}

    agent =
      %{
        client: client,
        model: "claude-opus-5-5",
        output_schema: %Decision{}
      }
      |> BaseAgent.init()
      |> BaseAgent.register_tool(%FakeTool{notify: self()})

    assert {:error, %LLMError{type: :max_tokens}} = BaseAgent.run(agent, "decide")
    assert_received {:body, %{"output_config" => %{"format" => _}}}
    refute_received {:body, _}
    refute_received {:tool_ran, _}
  end
end
