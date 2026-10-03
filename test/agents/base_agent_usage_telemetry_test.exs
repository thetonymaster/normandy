defmodule Normandy.Agents.BaseAgentUsageTelemetryTest do
  # async: false — one test sets the global Logger level to :info.
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Test.StubClient

  def forward_stop(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:stop, metadata})

  defp run_and_capture_stop(client, run) do
    id = "usage-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:normandy, :agent, :llm_call, :stop],
      &__MODULE__.forward_stop/4,
      self()
    )

    try do
      agent = BaseAgent.init(%{client: client, model: "claude-opus-5-5", temperature: nil})

      log =
        ExUnit.CaptureLog.capture_log([metadata: [:input_tokens, :output_tokens]], fn ->
          run.(agent)
        end)

      assert_receive {:stop, metadata}
      {metadata, log}
    after
      :telemetry.detach(id)
    end
  end

  defp stub_client(usage) do
    %StubClient{
      reply: fn response_model -> {Map.put(response_model, :chat_message, "hi"), usage} end
    }
  end

  defp sse(events) do
    Enum.map_join(events, fn data ->
      "event: #{data["type"]}\ndata: #{Jason.encode!(data)}\n\n"
    end)
  end

  defp stream_client(name, start_usage, delta_usage) do
    events = [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => [],
          "usage" => start_usage
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
        "usage" => delta_usage
      },
      %{"type" => "message_stop"}
    ]

    Req.Test.stub(name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse(events))
    end)

    %ClaudioAdapter{
      api_key: "k",
      options: %{req_options: [plug: {Req.Test, name}, retry: false]}
    }
  end

  @normalized [:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_write_input_tokens]

  test "non-streaming stop carries the raw usage and normalized counts beside it" do
    usage = %{
      input_tokens: 10,
      output_tokens: 5,
      cache_read_input_tokens: 100,
      cache_creation_input_tokens: 20
    }

    {metadata, _log} =
      run_and_capture_stop(stub_client(usage), &BaseAgent.run(&1, "hello"))

    assert metadata.usage == usage
    assert metadata.input_tokens == 130
    assert metadata.output_tokens == 5
    assert metadata.cache_read_input_tokens == 100
    assert metadata.cache_write_input_tokens == 20
  end

  test "a provider that reports no usage gets no normalized keys" do
    {metadata, _log} =
      run_and_capture_stop(
        %StubClient{reply: fn rm -> Map.put(rm, :chat_message, "hi") end},
        &BaseAgent.run(&1, "hello")
      )

    for key <- @normalized, do: refute(Map.has_key?(metadata, key), "unexpected #{key}")
  end

  test "streaming stop carries usage from the final message and normalized counts" do
    client =
      stream_client(
        __MODULE__.Stream,
        %{
          "input_tokens" => 10,
          "output_tokens" => 0,
          "cache_read_input_tokens" => 100,
          "cache_creation_input_tokens" => 20
        },
        %{"output_tokens" => 7}
      )

    {metadata, _log} =
      run_and_capture_stop(client, &BaseAgent.stream_response(&1, "hello", fn _, _ -> :ok end))

    assert metadata.usage["input_tokens"] == 10
    assert metadata.usage["output_tokens"] == 7
    assert metadata.input_tokens == 130
    assert metadata.output_tokens == 7
    assert metadata.cache_read_input_tokens == 100
    assert metadata.cache_write_input_tokens == 20
  end

  test "the llm call stop log line carries the normalized token counts" do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    usage = %{input_tokens: 10, output_tokens: 5, cache_read_input_tokens: 100}

    {_metadata, log} =
      run_and_capture_stop(stub_client(usage), &BaseAgent.run(&1, "hello"))

    assert log =~ "normandy llm call stop"
    assert log =~ "input_tokens=110"
    assert log =~ "output_tokens=5"
  end
end
