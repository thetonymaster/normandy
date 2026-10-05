defmodule Normandy.Agents.BaseAgentServedByTest do
  # async: false — one test sets the global Logger level to :info.
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.StubClient

  # Answers "hi" with usage, plus `meta` when it is set.
  defp meta_client(meta) do
    usage = %{input_tokens: 1, output_tokens: 1}

    %StubClient{
      reply: fn response_model ->
        response = Map.put(response_model, :chat_message, "hi")
        {:ok, %Normandy.LLM.Response{content: response, usage: usage, meta: meta || %{}}}
      end
    }
  end

  def forward_stop(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:stop, metadata})

  # Returns {stop_metadata, captured_log}. Logs are captured so the run stays quiet.
  defp run_and_capture_stop(client, run \\ &BaseAgent.run!(&1, "hello")) do
    test_pid = self()
    id = "served-by-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:normandy, :agent, :llm_call, :stop],
      &__MODULE__.forward_stop/4,
      test_pid
    )

    try do
      agent = BaseAgent.init(%{client: client, model: "claude-opus-5-5", temperature: nil})

      log =
        ExUnit.CaptureLog.capture_log([metadata: [:served_by]], fn ->
          run.(agent)
        end)

      assert_receive {:stop, metadata}
      {metadata, log}
    after
      :telemetry.detach(id)
    end
  end

  test "llm_call stop metadata carries served_by when the model reports it" do
    {metadata, _log} = run_and_capture_stop(meta_client(%{served_by: "claude-opus-5"}))
    assert metadata.served_by == "claude-opus-5"
  end

  test "llm_call stop metadata has no served_by when the model reports none" do
    {metadata, _log} = run_and_capture_stop(meta_client(nil))
    refute Map.has_key?(metadata, :served_by)
  end

  test "the llm call stop log line carries served_by" do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    {_metadata, log} = run_and_capture_stop(meta_client(%{served_by: "claude-opus-5"}))

    assert log =~ "normandy llm call stop"
    assert log =~ "served_by=claude-opus-5"
  end

  describe "streaming" do
    alias Normandy.LLM.ClaudioAdapter

    @streamed_drop %{
      "type" => "thinking_dropped",
      "path" => "messages.1.content.0",
      "reason" => "prefix_binding_mismatch"
    }

    defp sse(events) do
      Enum.map_join(events, fn data ->
        "event: #{data["type"]}\ndata: #{Jason.encode!(data)}\n\n"
      end)
    end

    # A one-text-block streamed reply. `start` is merged into message_start's
    # message, `delta` into the message_delta event.
    defp stream_client(name, start, delta) do
      events = [
        %{
          "type" => "message_start",
          "message" =>
            Map.merge(
              %{
                "id" => "msg_1",
                "type" => "message",
                "role" => "assistant",
                "model" => "claude-opus-5-5",
                "content" => [],
                "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
              },
              start
            )
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
        Map.merge(
          %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 1}
          },
          delta
        ),
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

    defp stream_and_capture_stop(client) do
      run_and_capture_stop(client, fn agent ->
        BaseAgent.stream(agent, "hello", fn _ -> :ok end)
      end)
    end

    test "llm_call stop metadata carries served_by" do
      {metadata, _log} = stream_and_capture_stop(stream_client(__MODULE__.Served, %{}, %{}))
      assert metadata.served_by == "claude-opus-5-5"
    end

    test "llm_call stop metadata carries message_start's input_transformations, logged" do
      client =
        stream_client(__MODULE__.Start, %{"input_transformations" => [@streamed_drop]}, %{})

      {metadata, log} = stream_and_capture_stop(client)

      assert metadata.input_transformations == [@streamed_drop]
      assert log =~ "thinking block dropped by the API"
      assert log =~ "messages.1.content.0"
    end

    test "message_delta's input_transformations replace message_start's" do
      later = %{@streamed_drop | "path" => "messages.3.content.0"}

      client =
        stream_client(
          __MODULE__.Delta,
          %{"input_transformations" => [@streamed_drop]},
          %{"input_transformations" => [later]}
        )

      {metadata, _log} = stream_and_capture_stop(client)
      assert metadata.input_transformations == [later]
    end
  end

  describe "thinking blocks the API dropped" do
    @dropped %{
      "type" => "thinking_dropped",
      "path" => "messages.1.content.0",
      "reason" => "prefix_binding_mismatch"
    }

    test "llm_call stop metadata carries the API's input_transformations" do
      {metadata, _log} = run_and_capture_stop(meta_client(%{input_transformations: [@dropped]}))
      assert metadata.input_transformations == [@dropped]
    end

    test "a dropped thinking block is logged as a warning with its path and reason" do
      {_metadata, log} = run_and_capture_stop(meta_client(%{input_transformations: [@dropped]}))

      assert log =~ "[warning]"
      assert log =~ "thinking block dropped by the API"
      assert log =~ "messages.1.content.0"
      assert log =~ "prefix_binding_mismatch"
    end
  end
end
