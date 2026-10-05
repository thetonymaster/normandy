defmodule Normandy.Telemetry.LlmCallRequestMetadataTest do
  # async: false — attaches global telemetry handlers.
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLM.{ClaudioAdapter, OpenAICompatibleAdapter}
  alias Normandy.Telemetry.Provider
  alias Normandy.Test.StubClient

  def forward(event, _measurements, metadata, test_pid),
    do: send(test_pid, {event, metadata})

  # Returns {start_metadata, stop_metadata} of the first llm_call.
  defp capture(client, run, config \\ %{}) do
    id = "llm-call-request-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      [[:normandy, :agent, :llm_call, :start], [:normandy, :agent, :llm_call, :stop]],
      &__MODULE__.forward/4,
      self()
    )

    try do
      agent =
        BaseAgent.init(
          Map.merge(%{client: client, model: "claude-opus-5-5", temperature: nil}, config)
        )

      ExUnit.CaptureLog.capture_log(fn -> run.(agent) end)

      assert_receive {[:normandy, :agent, :llm_call, :start], start}
      assert_receive {[:normandy, :agent, :llm_call, :stop], stop}
      {start, stop}
    after
      :telemetry.detach(id)
    end
  end

  defp stub_client(options \\ %{}) do
    %StubClient{
      options: options,
      reply: fn model ->
        {:ok,
         %Normandy.LLM.Response{
           content: Map.put(model, :chat_message, "hi"),
           usage: %{input_tokens: 1, output_tokens: 1},
           meta: %{response_id: "msg_stub", finish_reason: :end_turn}
         }}
      end
    }
  end

  defp run_it(agent), do: BaseAgent.run(agent, "hello")

  describe "Provider.provider/1" do
    test "names the known adapters" do
      assert Provider.provider(%ClaudioAdapter{api_key: "k"}) == :anthropic
      assert Provider.provider(%OpenAICompatibleAdapter{api_key: "k"}) == :openai_compatible
    end

    test "a custom client may name itself in options, else nil" do
      assert Provider.provider(%StubClient{options: %{provider: :acme}}) == :acme
      assert Provider.provider(%StubClient{}) == nil
      assert Provider.provider(:not_a_client) == nil
    end
  end

  describe "Provider.server_address/1" do
    test "is the host of the base URL" do
      assert Provider.server_address(%OpenAICompatibleAdapter{
               api_key: "k",
               base_url: "https://llm.example.com:8443/v1"
             }) == "llm.example.com"

      assert Provider.server_address(%ClaudioAdapter{
               api_key: "k",
               base_url: "http://localhost:4000"
             }) ==
               "localhost"
    end

    test "is nil when no base URL is known" do
      assert Provider.server_address(%ClaudioAdapter{api_key: "k"}) == nil
      assert Provider.server_address(%StubClient{}) == nil
    end
  end

  describe "non-streaming start metadata" do
    test "carries provider, stream, max_tokens, temperature, effort, structured_output" do
      client = %{
        stub_client(%{provider: :acme, effort: :high})
        | options: %{provider: :acme, effort: :high}
      }

      {start, _stop} =
        capture(client, &run_it/1, %{max_tokens: 321, temperature: 0.4})

      assert start.provider == :acme
      assert start.stream == false
      assert start.max_tokens == 321
      assert start.temperature == 0.4
      assert start.effort == :high
      assert start.structured_output == false
      refute Map.has_key?(start, :server_address)
    end

    test "omits temperature, effort and provider when unset" do
      {start, _stop} = capture(stub_client(), &run_it/1)

      refute Map.has_key?(start, :temperature)
      refute Map.has_key?(start, :effort)
      refute Map.has_key?(start, :provider)
      assert start.stream == false
    end

    test "carries server_address from the client base URL" do
      client = %{stub_client() | options: %{base_url: "https://proxy.example.com/v1"}}
      {start, _stop} = capture(client, &run_it/1)
      assert start.server_address == "proxy.example.com"
    end
  end

  describe "non-streaming stop metadata" do
    test "carries response_id and finish_reason from the adapter meta" do
      {_start, stop} = capture(stub_client(), &run_it/1)
      assert stop.response_id == "msg_stub"
      assert stop.finish_reason == "end_turn"
    end

    test "has neither when the adapter reports none" do
      client = %StubClient{
        reply: fn model ->
          {:ok,
           %Normandy.LLM.Response{
             content: Map.put(model, :chat_message, "hi"),
             usage: %{input_tokens: 1}
           }}
        end
      }

      {_start, stop} = capture(client, &run_it/1)
      refute Map.has_key?(stop, :response_id)
      refute Map.has_key?(stop, :finish_reason)
    end
  end

  describe "Claudio adapter, non-streaming" do
    @reply %{
      "id" => "msg_abc",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5-5",
      "content" => [%{"type" => "text", "text" => ~s({"chat_message":"hi"})}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    defp claudio(name, options \\ %{}) do
      Req.Test.stub(name, fn conn -> Req.Test.json(conn, @reply) end)

      %ClaudioAdapter{
        api_key: "k",
        options: Map.merge(%{req_options: [plug: {Req.Test, name}, retry: false]}, options)
      }
    end

    test "start is :anthropic with structured_output true; stop has id and finish_reason" do
      {start, stop} = capture(claudio(__MODULE__.NonStream), &run_it/1)

      assert start.provider == :anthropic
      assert start.structured_output == true
      assert stop.response_id == "msg_abc"
      assert stop.finish_reason == "end_turn"
    end

    test "structured_output is false when the kill-switch is off" do
      client = claudio(__MODULE__.NoStructured, %{structured_outputs: false})
      {start, _stop} = capture(client, &run_it/1)
      assert start.structured_output == false
    end
  end

  describe "OpenAI-compatible adapter, non-streaming" do
    test "start has the provider and host; stop has id and finish_reason" do
      Req.Test.stub(__MODULE__.OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "id" => "chatcmpl-1",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => ~s({"chat_message":"hi"})},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      end)

      client = %OpenAICompatibleAdapter{
        api_key: "k",
        base_url: "https://llm.example.com/v1",
        options: %{req_options: [plug: {Req.Test, __MODULE__.OpenAI}, retry: false]}
      }

      {start, stop} = capture(client, &run_it/1)

      assert start.provider == :openai_compatible
      assert start.server_address == "llm.example.com"
      assert start.structured_output == false
      assert stop.response_id == "chatcmpl-1"
      assert stop.finish_reason == "stop"
    end
  end

  describe "streaming" do
    defp sse(events) do
      Enum.map_join(events, fn data ->
        "event: #{data["type"]}\ndata: #{Jason.encode!(data)}\n\n"
      end)
    end

    defp stream_client(name, options \\ %{}, mode \\ :text) do
      events = [
        %{
          "type" => "message_start",
          "message" => %{
            "id" => "msg_s1",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-opus-5-5",
            "content" => [],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
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

      events = stream_events(events, mode)

      Req.Test.stub(name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse(events))
      end)

      %ClaudioAdapter{
        api_key: "k",
        options: Map.merge(%{req_options: [plug: {Req.Test, name}, retry: false]}, options)
      }
    end

    defp stream_events(events, :text), do: events

    defp stream_events(events, :empty),
      do: Enum.reject(events, &(&1["type"] in ["content_block_delta"]))

    defp stream_events(events, :tool_use) do
      Enum.map(events, fn
        %{"type" => "content_block_start"} = e ->
          %{
            e
            | "content_block" => %{
                "type" => "tool_use",
                "id" => "toolu_1",
                "name" => "lookup",
                "input" => %{}
              }
          }

        %{"type" => "content_block_delta"} = e ->
          %{e | "delta" => %{"type" => "input_json_delta", "partial_json" => "{}"}}

        e ->
          e
      end)
    end

    defp stream_it(agent), do: BaseAgent.stream_response(agent, "hello", fn _, _ -> :ok end)

    test "start metadata carries the request facts with stream true" do
      client = stream_client(__MODULE__.S1, %{effort: :low})

      {start, _stop} = capture(client, &stream_it/1, %{max_tokens: 99, temperature: 0.2})

      assert start.provider == :anthropic
      assert start.stream == true
      assert start.max_tokens == 99
      assert start.temperature == 0.2
      assert start.effort == :low
      assert start.structured_output == false
    end

    test "stop metadata carries response_id, finish_reason and time_to_first_chunk" do
      {_start, stop} = capture(stream_client(__MODULE__.S2), &stream_it/1)

      assert stop.response_id == "msg_s1"
      assert stop.finish_reason == "end_turn"
      assert is_integer(stop.time_to_first_chunk)
      assert stop.time_to_first_chunk >= 0
    end

    test "time_to_first_chunk is set for a tool-use-only stream" do
      client = stream_client(__MODULE__.S4, %{}, :tool_use)
      {_start, stop} = capture(client, &stream_it/1)

      assert is_integer(stop.time_to_first_chunk)
      assert stop.time_to_first_chunk >= 0
    end

    test "time_to_first_chunk is absent when the stream has no content events" do
      client = stream_client(__MODULE__.S3, %{}, :empty)
      {_start, stop} = capture(client, &stream_it/1)
      refute Map.has_key?(stop, :time_to_first_chunk)
      assert stop.response_id == "msg_s1"
    end

    test "time_to_first_chunk is measured from the attempt that delivered it" do
      client = struct!(__MODULE__.RetryClient)

      {_start, stop} =
        capture(client, &stream_it/1, %{
          retry_options: [max_attempts: 2, base_delay: 300, jitter: false]
        })

      ms = System.convert_time_unit(stop.time_to_first_chunk, :native, :millisecond)
      assert ms < 150
    end
  end

  # First stream/3 call fails retryably; the retry streams one text delta.
  defmodule RetryClient do
    defstruct counter: nil, options: %{}
  end

  defimpl Normandy.Agents.Model, for: Normandy.Telemetry.LlmCallRequestMetadataTest.RetryClient do
    def converse(_c, request, _opts),
      do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

    def stream(_client, _request, _opts) do
      key = {__MODULE__, self()}
      n = Process.get(key, 0)
      Process.put(key, n + 1)

      if n == 0 do
        {:error, Normandy.LLMError.new(type: :rate_limit, status: 429, retryable?: true)}
      else
        events = [
          %{type: "message_start", message: %{"id" => "m", "role" => "assistant"}},
          %{
            type: "content_block_start",
            content_block: %{"type" => "text", "text" => ""},
            index: 0
          },
          %{
            type: "content_block_delta",
            delta: %{"type" => "text_delta", "text" => "hi"},
            index: 0
          },
          %{type: "content_block_stop", index: 0},
          %{type: "message_delta", delta: %{"stop_reason" => "end_turn"}, usage: %{}},
          %{type: "message_stop"}
        ]

        {:ok, Stream.map(events, & &1)}
      end
    end
  end
end
