defmodule Normandy.Telemetry.LlmRequestSpanTest do
  # async: false — attaches global telemetry handlers.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, Model}
  alias Normandy.Components.Message
  alias Normandy.LLM.{ClaudioAdapter, OpenAICompatibleAdapter}
  alias Normandy.LLMError
  alias Normandy.Test.StubClient

  @request [:normandy, :llm, :request]
  @llm_call [:normandy, :agent, :llm_call]

  def forward(event, measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, measurements, metadata})

  setup do
    id = "llm-request-span-#{System.unique_integer([:positive])}"

    events =
      for prefix <- [@request, @llm_call],
          suffix <- [:start, :stop, :exception],
          do: prefix ++ [suffix]

    :telemetry.attach_many(id, events, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  # Every request event received so far, in order: {suffix, metadata}.
  defp request_events do
    receive do
      {:telemetry, @request ++ [suffix], _measurements, metadata} ->
        [{suffix, metadata} | request_events()]
    after
      0 -> []
    end
  end

  defp llm_call_stop do
    assert_receive {:telemetry, @llm_call ++ [:stop], _m, metadata}
    metadata
  end

  defp agent(client, config \\ %{}) do
    BaseAgent.init(
      Map.merge(%{client: client, model: "claude-opus-5-5", temperature: nil}, config)
    )
  end

  defp reply(text, id \\ "msg_ok") do
    %{
      "id" => id,
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5-5",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{
        "input_tokens" => 3,
        "output_tokens" => 2,
        "cache_read_input_tokens" => 10
      }
    }
  end

  defp error_reply(conn, status, type, message) do
    conn
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(%{"type" => "error", "error" => %{"type" => type, "message" => message}})
  end

  # A Req.Test stub that answers the n-th request (0-based) with responses.(n, conn).
  defp claudio(name, options, responses) do
    counter = :counters.new(1, [])

    Req.Test.stub(name, fn conn ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      responses.(n, conn)
    end)

    %ClaudioAdapter{
      api_key: "k",
      options: Map.merge(%{req_options: [plug: {Req.Test, name}, retry: false]}, options)
    }
  end

  @valid ~s({"chat_message":"hi"})

  describe "Claudio adapter, non-streaming" do
    test "one request: start and stop carry the request facts" do
      client = claudio(__MODULE__.One, %{}, fn _n, conn -> Req.Test.json(conn, reply(@valid)) end)

      BaseAgent.run(agent(client), "hello")

      assert [{:start, start}, {:stop, stop}] = request_events()

      assert start.model == "claude-opus-5-5"
      assert start.provider == :anthropic
      assert start.attempt == 1
      assert start.kind == :initial
      assert start.stream == false
      assert is_binary(start.turn_id)
      assert start.agent_name == nil or is_binary(start.agent_name)

      assert stop.attempt == 1
      assert stop.response_id == "msg_ok"
      assert stop.finish_reason == "end_turn"
      assert stop.status == :ok
      assert stop.input_tokens == 13
      assert stop.output_tokens == 2
      assert stop.cache_read_input_tokens == 10
      refute Map.has_key?(stop, :usage)

      call = llm_call_stop()
      assert call.attempts == 1
      assert call.json_retries == 0
      assert call.structured_fallback == false
    end

    test "a BaseAgent retry is a second request of kind :retry; the failure is an exception" do
      client =
        claudio(__MODULE__.Retry, %{}, fn
          0, conn -> error_reply(conn, 429, "rate_limit_error", "slow down")
          _n, conn -> Req.Test.json(conn, reply(@valid))
        end)

      BaseAgent.run(
        agent(client, %{retry_options: [max_attempts: 2, base_delay: 1, jitter: false]}),
        "hello"
      )

      assert [
               {:start, %{attempt: 1, kind: :initial}},
               {:exception, failed},
               {:start, %{attempt: 2, kind: :retry}},
               {:stop, %{attempt: 2, status: :ok}}
             ] = request_events()

      assert failed.kind == :error
      assert %LLMError{type: :rate_limit} = failed.reason
      assert failed.attempt == 1

      call = llm_call_stop()
      assert call.attempts == 2
      assert call.json_retries == 0
      assert call.structured_fallback == false
    end

    test "a JSON parse retry is a request of kind :json_retry" do
      client =
        claudio(__MODULE__.Json, %{structured_outputs: false}, fn
          0, conn -> Req.Test.json(conn, reply("not json at all", "msg_bad"))
          _n, conn -> Req.Test.json(conn, reply(@valid))
        end)

      BaseAgent.run(agent(client), "hello")

      assert [
               {:start, %{attempt: 1, kind: :initial}},
               {:stop, %{attempt: 1, response_id: "msg_bad"}},
               {:start, %{attempt: 2, kind: :json_retry}},
               {:stop, %{attempt: 2, response_id: "msg_ok"}}
             ] = request_events()

      call = llm_call_stop()
      assert call.attempts == 2
      assert call.json_retries == 1
      assert call.structured_fallback == false
    end

    test "the structured-outputs 400 fallback is a request of kind :structured_fallback" do
      client =
        claudio(__MODULE__.Fallback, %{}, fn
          0, conn -> error_reply(conn, 400, "invalid_request_error", "output_format unsupported")
          _n, conn -> Req.Test.json(conn, reply(@valid))
        end)

      BaseAgent.run(agent(client), "hello")

      assert [
               {:start, %{attempt: 1, kind: :initial}},
               {:exception, %{reason: %LLMError{type: :invalid_request}}},
               {:start, %{attempt: 2, kind: :structured_fallback}},
               {:stop, %{attempt: 2}}
             ] = request_events()

      call = llm_call_stop()
      assert call.attempts == 2
      assert call.json_retries == 0
      assert call.structured_fallback == true
    end

    test "attempt numbers keep counting across a BaseAgent retry after inner requests" do
      client =
        claudio(__MODULE__.Mixed, %{structured_outputs: false}, fn
          0, conn -> Req.Test.json(conn, reply("not json", "msg_bad"))
          1, conn -> error_reply(conn, 529, "overloaded_error", "busy")
          _n, conn -> Req.Test.json(conn, reply(@valid))
        end)

      BaseAgent.run(
        agent(client, %{retry_options: [max_attempts: 2, base_delay: 1, jitter: false]}),
        "hello"
      )

      starts = for {:start, m} <- request_events(), do: {m.attempt, m.kind}
      assert starts == [{1, :initial}, {2, :json_retry}, {3, :retry}]

      call = llm_call_stop()
      assert call.attempts == 3
      assert call.json_retries == 1
    end

    test "a direct Model.converse call with no tracker still emits one request span" do
      client =
        claudio(__MODULE__.Direct, %{}, fn _n, conn -> Req.Test.json(conn, reply(@valid)) end)

      Model.converse(
        client,
        "claude-opus-5-5",
        nil,
        64,
        [%Message{role: "user", content: "hi"}],
        %Normandy.Agents.BaseAgentOutputSchema{},
        []
      )

      assert [{:start, %{attempt: 1, kind: :initial}}, {:stop, _}] = request_events()
    end
  end

  describe "OpenAI-compatible adapter" do
    test "one request span with normalized usage" do
      Req.Test.stub(__MODULE__.OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "id" => "chatcmpl-1",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => @valid},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 1}
        })
      end)

      client = %OpenAICompatibleAdapter{
        api_key: "k",
        base_url: "https://llm.example.com/v1",
        options: %{req_options: [plug: {Req.Test, __MODULE__.OpenAI}, retry: false]}
      }

      BaseAgent.run(agent(client), "hello")

      assert [{:start, start}, {:stop, stop}] = request_events()
      assert start.provider == :openai_compatible
      assert start.kind == :initial
      assert stop.response_id == "chatcmpl-1"
      assert stop.finish_reason == "stop"
      assert stop.input_tokens == 4
      assert stop.output_tokens == 1
      assert stop.status == :ok
    end

    test "an HTTP error is an exception carrying the LLMError" do
      Req.Test.stub(__MODULE__.OpenAIErr, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => %{"message" => "no"}})
      end)

      client = %OpenAICompatibleAdapter{
        api_key: "k",
        base_url: "https://llm.example.com/v1",
        options: %{req_options: [plug: {Req.Test, __MODULE__.OpenAIErr}, retry: false]}
      }

      assert_raise LLMError, fn -> BaseAgent.run(agent(client), "hello") end

      assert [
               {:start, _},
               {:exception, %{kind: :error, reason: %LLMError{type: :authentication}}}
             ] =
               request_events()
    end
  end

  describe "a client that emits no request spans" do
    test "llm_call stop counts BaseAgent's converse calls as attempts" do
      client = %StubClient{reply: fn model -> Map.put(model, :chat_message, "hi") end}

      BaseAgent.run(agent(client), "hello")

      assert request_events() == []
      call = llm_call_stop()
      assert call.attempts == 1
      assert call.json_retries == 0
      assert call.structured_fallback == false
    end
  end

  describe "streaming" do
    defp sse(events) do
      Enum.map_join(events, fn data ->
        "event: #{data["type"]}\ndata: #{Jason.encode!(data)}\n\n"
      end)
    end

    @stream_events [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_s1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => [],
          "usage" => %{"input_tokens" => 5, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "hi"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 1}
      },
      %{"type" => "message_stop"}
    ]

    test "each stream attempt is one request span; a retried stream is attempt 2 :retry" do
      client =
        claudio(__MODULE__.Stream, %{}, fn
          0, conn ->
            error_reply(conn, 429, "rate_limit_error", "slow down")

          _n, conn ->
            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_resp(200, sse(@stream_events))
        end)

      BaseAgent.stream_response(
        agent(client, %{retry_options: [max_attempts: 2, base_delay: 1, jitter: false]}),
        "hello",
        fn _, _ -> :ok end
      )

      assert [
               {:start, %{attempt: 1, kind: :initial, stream: true, provider: :anthropic}},
               {:exception, %{reason: %LLMError{}}},
               {:start, %{attempt: 2, kind: :retry, stream: true}},
               {:stop, stop}
             ] = request_events()

      assert stop.response_id == "msg_s1"
      assert stop.finish_reason == "end_turn"
      assert stop.input_tokens == 5
      assert stop.output_tokens == 1
      assert stop.status == :ok

      call = llm_call_stop()
      assert call.attempts == 2
      assert call.json_retries == 0
      assert call.structured_fallback == false
    end
  end
end
