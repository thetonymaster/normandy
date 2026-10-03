defmodule Normandy.LLM.ClaudioAdapterFailedUsageTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.Model
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLMError

  defp client(stub, extra) do
    %ClaudioAdapter{
      api_key: "k",
      options:
        Map.merge(
          %{
            on_parse_failure: :error,
            req_options: [plug: {Req.Test, stub}, retry: false]
          },
          extra
        )
    }
  end

  defp converse(client) do
    Model.converse(
      client,
      "claude-opus-5-5",
      nil,
      1024,
      [%Message{role: "user", content: "hi"}],
      %Normandy.Agents.BaseAgentOutputSchema{},
      []
    )
  end

  defp garbage_reply(conn, input, output) do
    Req.Test.json(conn, %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5-5",
      "content" => [%{"type" => "text", "text" => "not json at all"}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => input, "output_tokens" => output}
    })
  end

  test "exhausted JSON parse retries: the error carries the summed usage of every call" do
    stub = __MODULE__.Exhausted

    Req.Test.stub(stub, fn conn -> garbage_reply(conn, 10, 2) end)

    assert {:error, %LLMError{type: :invalid_output} = error} =
             converse(client(stub, %{structured_outputs: false}))

    # first call + 2 JSON retries
    assert error.usage.input_tokens == 30
    assert error.usage.output_tokens == 6
    assert error.usage_counts == %{input_tokens: 30, output_tokens: 6}
  end

  test "an LLM failure during a JSON retry keeps the usage already paid" do
    stub = __MODULE__.RetryFails
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub, fn conn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          garbage_reply(conn, 10, 2)

        _ ->
          conn
          |> Plug.Conn.put_status(500)
          |> Req.Test.json(%{
            "type" => "error",
            "error" => %{"type" => "api_error", "message" => "boom"}
          })
      end
    end)

    assert {:error, %LLMError{type: :server} = error} =
             converse(client(stub, %{structured_outputs: false}))

    assert error.usage_counts == %{input_tokens: 10, output_tokens: 2}
  end

  test "structured-outputs response that does not parse: the error carries that call's usage" do
    stub = __MODULE__.Structured

    Req.Test.stub(stub, fn conn -> garbage_reply(conn, 7, 3) end)

    assert {:error, %LLMError{type: :invalid_output} = error} = converse(client(stub, %{}))
    assert error.usage_counts == %{input_tokens: 7, output_tokens: 3}
  end

  test "structured 400 falling back to legacy: usage is the legacy call's, summed with its retries" do
    stub = __MODULE__.Fallback
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub, fn conn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{
            "type" => "error",
            "error" => %{
              "type" => "invalid_request_error",
              "message" => "output_format schema is not supported"
            }
          })

        _ ->
          garbage_reply(conn, 5, 1)
      end
    end)

    assert {:error, %LLMError{type: :invalid_output} = error} = converse(client(stub, %{}))
    assert error.usage_counts == %{input_tokens: 15, output_tokens: 3}
  end

  test "an error without paid calls has no usage" do
    e = LLMError.new(type: :server, retryable?: true)
    assert e.usage == nil
    assert e.usage_counts == nil
  end
end
