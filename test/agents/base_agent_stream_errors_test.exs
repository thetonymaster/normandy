defmodule Normandy.Agents.BaseAgentStreamErrorsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Guardrails.Builtins.ForbiddenSubstrings
  alias Normandy.LLMError

  # stream/3 returns {:ok, events} (a list is Enumerable) or {:error, %LLMError{}}.
  defmodule EventsClient do
    defstruct events: [], connect_error: nil, api_key: nil
  end

  defimpl Normandy.Agents.Model, for: Normandy.Agents.BaseAgentStreamErrorsTest.EventsClient do
    def converse(_c, request, _opts),
      do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

    def stream(%{connect_error: nil} = client, _request, _opts),
      do: {:ok, client.events}

    def stream(client, _request, _opts),
      do: {:error, client.connect_error}
  end

  defp start, do: %{type: "message_start", message: %{"id" => "m", "role" => "assistant"}}

  defp block,
    do: %{type: "content_block_start", content_block: %{"type" => "text", "text" => ""}, index: 0}

  defp delta(text),
    do: %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}, index: 0}

  defp error_event,
    do: %{type: "error", error: %{"type" => "overloaded_error", "message" => "Overloaded"}}

  defp agent(events, extra \\ %{}) do
    BaseAgent.init(
      Map.merge(
        %{client: %EventsClient{events: events}, model: "claude-opus-5-5", temperature: nil},
        extra
      )
    )
  end

  defp stream(agent),
    do: BaseAgent.stream_response(agent, %{chat_message: "hi"}, fn _, _ -> :ok end)

  @incremental %{
    output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}],
    output_guardrails_streaming_mode: :incremental,
    output_guardrails_chunk_size: 5
  }

  test "a mid-stream error event raises" do
    agent = agent([start(), block(), delta("Hel"), error_event()])

    assert_raise LLMError, "LLM call failed: stream: Overloaded", fn -> stream(agent) end
  end

  defp usage_start(usage),
    do: %{type: "message_start", message: %{"id" => "m", "role" => "assistant", "usage" => usage}}

  defp reason_of(fun) do
    fun.()
    flunk("expected an LLMError")
  rescue
    e in LLMError -> e
  end

  test "a stream that errors after message_start carries its usage on the error" do
    events = [
      usage_start(%{"input_tokens" => 12}),
      block(),
      delta("Hel"),
      error_event()
    ]

    e = reason_of(fn -> stream(agent(events)) end)
    assert e.usage_counts == %{input_tokens: 12}
  end

  test "incremental-guardrail stream that errors also carries usage" do
    events = [
      usage_start(%{"input_tokens" => 12}),
      block(),
      delta("Hel"),
      error_event()
    ]

    e = reason_of(fn -> stream(agent(events, @incremental)) end)
    assert e.usage_counts == %{input_tokens: 12}
  end

  # Handlers are global and the module is async: only report this test's own process.
  def handle_llm_call(event, _measurements, _metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:llm_call_event, event})
  end

  def handle_exception(_event, _measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:exception_metadata, metadata})
  end

  test "a failed stream emits an llm_call :exception span, not :stop" do
    id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :telemetry.attach_many(
      id,
      [
        [:normandy, :agent, :llm_call, :stop],
        [:normandy, :agent, :llm_call, :exception]
      ],
      &__MODULE__.handle_llm_call/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(id) end)

    agent = agent([start(), block(), delta("Hel"), error_event()])
    assert_raise LLMError, fn -> stream(agent) end

    assert_received {:llm_call_event, [:normandy, :agent, :llm_call, :exception]}
    refute_received {:llm_call_event, [:normandy, :agent, :llm_call, :stop]}
  end

  test "a failed stream's exception telemetry and log line do not carry the config" do
    id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :telemetry.attach(
      id,
      [:normandy, :agent, :llm_call, :exception],
      &__MODULE__.handle_exception/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(id) end)

    agent =
      BaseAgent.init(%{
        client: %EventsClient{
          events: [start(), block(), delta("Hel"), error_event()],
          api_key: "sk-fv1-secret"
        },
        model: "claude-opus-5-5",
        temperature: nil
      })

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:reason]], fn ->
        assert_raise LLMError, fn -> stream(agent) end
      end)

    assert_received {:exception_metadata, metadata}
    refute inspect(metadata, limit: :infinity, printable_limit: :infinity) =~ "sk-fv1-secret"
    assert log =~ "normandy llm call exception"
    refute log =~ "sk-fv1-secret"
  end

  test "an {:error, _} item in the stream raises" do
    agent = agent([start(), block(), delta("Hel"), {:error, :closed}])

    assert %LLMError{type: :stream, reason: :closed} =
             assert_raise(LLMError, fn -> stream(agent) end)
  end

  test "a stream that ends without message_stop raises" do
    agent = agent([start(), block(), delta("Hel")])

    assert_raise LLMError, ~r/stream ended before message_stop/, fn -> stream(agent) end
  end

  test "a connection-time error raises it" do
    e = LLMError.new(type: :rate_limit, status: 429, retryable?: true)

    agent =
      BaseAgent.init(%{
        client: %EventsClient{connect_error: e},
        model: "claude-opus-5-5",
        temperature: nil
      })

    assert ^e = assert_raise(LLMError, fn -> stream(agent) end)
  end

  test "incremental guardrails: a mid-stream error event raises (not a guardrail halt)" do
    agent = agent([start(), block(), delta("Hello there"), error_event()], @incremental)

    assert_raise LLMError, ~r/Overloaded/, fn -> stream(agent) end
  end

  test "incremental guardrails: an {:error, _} item raises" do
    agent = agent([start(), block(), delta("Hello there"), {:error, :closed}], @incremental)

    assert %LLMError{type: :stream, reason: :closed} =
             assert_raise(LLMError, fn -> stream(agent) end)
  end

  test "incremental guardrails: a tail-check violation does not mask a stream error" do
    config = Map.put(@incremental, :output_guardrails, [{ForbiddenSubstrings, terms: ["badwd"]}])
    config = Map.put(config, :output_guardrails_chunk_size, 100)
    agent = agent([start(), block(), delta("badwd"), error_event()], config)

    assert_raise LLMError, ~r/Overloaded/, fn -> stream(agent) end
  end

  test "incremental guardrails: a violation halt is not an error" do
    agent =
      agent([start(), block(), delta("this has a badword in it"), delta(" more")], @incremental)

    {_agent, response} = stream(agent)
    assert response.guardrail_violations != []
  end
end
