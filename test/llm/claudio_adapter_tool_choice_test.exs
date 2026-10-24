defmodule Normandy.LLM.ClaudioAdapterToolChoiceTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Model
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLM.Request
  alias Normandy.Test.WireScript

  @tool %{name: "weather", description: "w", input_schema: %{type: "object"}}

  defp body_of(name, request) do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "m",
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })
    end)

    client = %ClaudioAdapter{
      api_key: "k",
      options: %{req_options: [plug: {Req.Test, name}, retry: false]}
    }

    {:ok, _response} = Model.converse(client, request, [])
    assert_received {:body, body}
    body
  end

  defp request(fields) do
    struct!(
      %Request{model: "m", max_tokens: 16, messages: [%Message{role: "user", content: "hi"}]},
      fields
    )
  end

  test "tool_choice :none is sent as {type: none} next to the tools" do
    body = body_of(__MODULE__.None, request(tools: [@tool], tool_choice: :none))

    assert body["tool_choice"] == %{"type" => "none"}
    assert [%{"name" => "weather"}] = body["tools"]
  end

  test "tool_choice nil leaves it to the API's default" do
    body = body_of(__MODULE__.Default, request(tools: [@tool]))
    refute Map.has_key?(body, "tool_choice")
  end

  test "tool_choice :none without any tool is left out (the API allows it only with tools)" do
    body = body_of(__MODULE__.NoTools, request(tool_choice: :none))
    refute Map.has_key?(body, "tool_choice")
  end

  # The stream request is built by build_request/3 too (X3).
  test "a stream request carries tool_choice :none" do
    client =
      WireScript.client([
        {:sse,
         WireScript.message(
           "msg_s",
           WireScript.block(0, %{"type" => "text", "text" => ""}, [
             %{"type" => "text_delta", "text" => "ok"}
           ]),
           "end_turn"
         )}
      ])

    {:ok, stream} = Model.stream(client, request(tools: [@tool], tool_choice: :none), [])
    Stream.run(stream)

    assert_received {:wire_body, 0, body}
    assert body["tool_choice"] == %{"type" => "none"}
    assert [%{"name" => "weather"}] = body["tools"]
  end
end
