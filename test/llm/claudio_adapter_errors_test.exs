defmodule Normandy.LLM.ClaudioAdapterErrorsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.Model
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLMError

  @key "sk-ant-test-canary-key"

  defp client(stub, extra_options \\ %{}) do
    %ClaudioAdapter{
      api_key: @key,
      options:
        Map.merge(
          %{req_options: [plug: {Req.Test, stub}, retry: false]},
          extra_options
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

  defp stub_error(stub, status, api_type, message) do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{
        "type" => "error",
        "error" => %{"type" => api_type, "message" => message}
      })
    end)
  end

  @matrix [
    {401, "authentication_error", :authentication, false},
    {403, "permission_error", :permission, false},
    {404, "not_found_error", :not_found, false},
    {400, "invalid_request_error", :invalid_request, false},
    {429, "rate_limit_error", :rate_limit, true},
    {529, "overloaded_error", :overloaded, true},
    {500, "api_error", :server, true},
    {408, "api_error", :server, true}
  ]

  describe "legacy path (structured_outputs: false)" do
    for {status, api_type, type, retryable?} <- @matrix do
      test "HTTP #{status} #{api_type} -> #{type}, retryable?: #{retryable?}" do
        stub_error(__MODULE__.Legacy, unquote(status), unquote(api_type), "boom")

        assert {:error, %LLMError{} = e} =
                 converse(client(__MODULE__.Legacy, %{structured_outputs: false}))

        assert e.type == unquote(type)
        assert e.status == unquote(status)
        assert e.retryable? == unquote(retryable?)
        assert e.message =~ "boom"
        refute inspect(e) =~ @key
      end
    end

    test "a transport error -> :transport, retryable" do
      Req.Test.stub(__MODULE__.Transport, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %LLMError{type: :transport, retryable?: true, status: nil} = e} =
               converse(client(__MODULE__.Transport, %{structured_outputs: false}))

      refute inspect(e) =~ @key
    end

    test "an API error during a parse retry is returned, not applied as a parse failure" do
      test_pid = self()
      counter = :counters.new(1, [])

      Req.Test.stub(__MODULE__.ParseRetry, fn conn ->
        :counters.add(counter, 1, 1)
        send(test_pid, :request)

        if :counters.get(counter, 1) == 1 do
          Req.Test.json(conn, %{
            "id" => "msg_1",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-opus-5-5",
            "content" => [%{"type" => "text", "text" => "this is not json"}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          })
        else
          conn
          |> Plug.Conn.put_status(529)
          |> Req.Test.json(%{
            "type" => "error",
            "error" => %{"type" => "overloaded_error", "message" => "busy"}
          })
        end
      end)

      assert {:error, %LLMError{type: :overloaded, status: 529}} =
               Model.converse(
                 client(__MODULE__.ParseRetry, %{structured_outputs: false}),
                 "claude-opus-5-5",
                 nil,
                 1024,
                 [%Message{role: "user", content: "hi"}],
                 %Normandy.LLM.Json.TestFixtures.MultiField{},
                 []
               )

      assert_received :request
      assert_received :request
      refute_received :request
    end
  end

  describe "structured path (default)" do
    test "a non-request-shape error is returned at the top level, not inside a tuple" do
      stub_error(__MODULE__.Structured, 529, "overloaded_error", "busy")

      assert {:error, %LLMError{type: :overloaded, status: 529}} =
               converse(client(__MODULE__.Structured))
    end

    defp stub_invalid_request(name, message) do
      test_pid = self()

      Req.Test.stub(name, fn conn ->
        send(test_pid, :request)

        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "type" => "error",
          "error" => %{"type" => "invalid_request_error", "message" => message}
        })
      end)
    end

    test "a schema rejection falls back to legacy once, then returns the error" do
      stub_invalid_request(__MODULE__.Fallback, "output_config.format.schema: unsupported")

      assert {:error, %LLMError{type: :invalid_request}} = converse(client(__MODULE__.Fallback))
      assert_received :request
      assert_received :request
      refute_received :request
    end

    test "any other invalid_request_error is returned without a second request" do
      stub_invalid_request(__MODULE__.TooLong, "prompt is too long: 250000 tokens > 200000")

      assert {:error, %LLMError{type: :invalid_request}} = converse(client(__MODULE__.TooLong))
      assert_received :request
      refute_received :request
    end
  end

  describe "stream_converse/7" do
    test "a connection-time HTTP error is classified (streaming errors arrive as :api_error)" do
      Req.Test.stub(__MODULE__.Stream, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Plug.Conn.send_resp(429, "")
      end)

      stream_client = client(__MODULE__.Stream)

      assert {:error, %LLMError{type: :rate_limit, status: 429, retryable?: true}} =
               Model.impl_for(stream_client).stream_converse(
                 stream_client,
                 "claude-opus-5-5",
                 nil,
                 1024,
                 [%Message{role: "user", content: "hi"}],
                 %Normandy.Agents.BaseAgentOutputSchema{},
                 []
               )
    end
  end

  describe "__to_llm_error__/1" do
    test "an unknown term is wrapped as :unknown" do
      assert %LLMError{type: :unknown, retryable?: false, reason: :weird} =
               ClaudioAdapter.__to_llm_error__(:weird)
    end
  end
end
