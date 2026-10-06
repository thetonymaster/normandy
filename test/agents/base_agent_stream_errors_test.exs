defmodule Normandy.Agents.BaseAgentStreamErrorsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.StreamEvent
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

  defp stream(agent, callback \\ fn _event -> :ok end),
    do: BaseAgent.stream(agent, %{chat_message: "hi"}, callback)

  # The LLMError stream/3 returns for a failed stream.
  defp error_of(agent) do
    assert {:error, %LLMError{} = error} = stream(agent)
    error
  end

  @incremental %{
    guardrails: [
      output: [{ForbiddenSubstrings, terms: ["badword"]}],
      streaming_mode: :incremental,
      chunk_size: 5
    ]
  }

  test "a mid-stream error event is an LLMError" do
    agent = agent([start(), block(), delta("Hel"), error_event()])

    assert Exception.message(error_of(agent)) == "LLM call failed: stream: Overloaded"
  end

  defp usage_start(usage),
    do: %{type: "message_start", message: %{"id" => "m", "role" => "assistant", "usage" => usage}}

  test "a stream that errors after message_start carries its usage on the error" do
    events = [
      usage_start(%{"input_tokens" => 12}),
      block(),
      delta("Hel"),
      error_event()
    ]

    e = error_of(agent(events))
    assert e.usage_counts == %{input_tokens: 12}
  end

  test "incremental-guardrail stream that errors also carries usage" do
    events = [
      usage_start(%{"input_tokens" => 12}),
      block(),
      delta("Hel"),
      error_event()
    ]

    e = error_of(agent(events, @incremental))
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
    error_of(agent)

    assert_received {:llm_call_event, [:normandy, :agent, :llm_call, :exception]}
    refute_received {:llm_call_event, [:normandy, :agent, :llm_call, :stop]}
  end

  test "a failed stream's llm_call :exception carries kind :error and the LLMError, like run/2" do
    id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :telemetry.attach(
      id,
      [:normandy, :agent, :llm_call, :exception],
      &__MODULE__.handle_exception/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(id) end)

    returned = error_of(agent([start(), block(), delta("Hel"), error_event()]))

    assert_received {:exception_metadata, %{kind: :error, reason: %LLMError{} = reason} = meta}
    assert reason == returned
    assert meta.stacktrace == []
  end

  test "a failed stream's exception telemetry does not carry the config, and it is not logged" do
    id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :telemetry.attach(
      id,
      [:normandy, :agent, :llm_call, :exception],
      &__MODULE__.handle_exception/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(id) end)

    # capture_log/2 sees every process's logs, so concurrent async tests may
    # log `[error]` lines on purpose. Only this run's marker can name this run.
    marker = "overloaded-#{System.unique_integer([:positive])}"

    agent =
      BaseAgent.init(%{
        client: %EventsClient{
          events: [
            start(),
            block(),
            delta("Hel"),
            %{type: "error", error: %{"type" => "overloaded_error", "message" => marker}}
          ],
          api_key: "sk-fv1-secret"
        },
        model: "claude-opus-5-5",
        temperature: nil
      })

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:reason]], fn ->
        send(test_pid, {:returned, error_of(agent)})
      end)

    assert_received {:returned, returned_error}
    assert_received {:exception_metadata, metadata}
    refute inspect(metadata, limit: :infinity, printable_limit: :infinity) =~ "sk-fv1-secret"
    # A returned Normandy error is recorded by telemetry, not logged.
    assert %LLMError{} = returned_error
    refute log =~ marker
    refute log =~ "sk-fv1-secret"
  end

  test "an {:error, _} item in the stream is an LLMError" do
    agent = agent([start(), block(), delta("Hel"), {:error, :closed}])

    assert %LLMError{type: :stream, reason: :closed} = error_of(agent)
  end

  test "a stream that ends without message_stop is an LLMError" do
    agent = agent([start(), block(), delta("Hel")])

    assert Exception.message(error_of(agent)) =~ "stream ended before message_stop"
  end

  test "a connection-time error is returned as is" do
    e = LLMError.new(type: :rate_limit, status: 429, retryable?: true)

    agent =
      BaseAgent.init(%{
        client: %EventsClient{connect_error: e},
        model: "claude-opus-5-5",
        temperature: nil
      })

    assert {:error, ^e} = stream(agent)
  end

  test "incremental guardrails: a mid-stream error event is an LLMError (not a guardrail halt)" do
    agent = agent([start(), block(), delta("Hello there"), error_event()], @incremental)

    assert Exception.message(error_of(agent)) =~ "Overloaded"
  end

  test "incremental guardrails: an {:error, _} item is an LLMError" do
    agent = agent([start(), block(), delta("Hello there"), {:error, :closed}], @incremental)

    assert %LLMError{type: :stream, reason: :closed} = error_of(agent)
  end

  test "incremental guardrails: a tail-check violation does not mask a stream error" do
    config = %{
      @incremental
      | guardrails: [
          output: [{ForbiddenSubstrings, terms: ["badwd"]}],
          streaming_mode: :incremental,
          chunk_size: 100
        ]
    }

    agent = agent([start(), block(), delta("badwd"), error_event()], config)

    assert Exception.message(error_of(agent)) =~ "Overloaded"
  end

  test "incremental guardrails: a violation halt is not an error" do
    agent =
      agent([start(), block(), delta("this has a badword in it"), delta(" more")], @incremental)

    test_pid = self()

    assert {:ok, _agent, _response} =
             stream(agent, fn
               %StreamEvent{type: :guardrail_violation, data: data} ->
                 send(test_pid, {:violation, data})

               _event ->
                 :ok
             end)

    assert_received {:violation, %{mode: :incremental, violations: [_ | _]}}
  end
end
