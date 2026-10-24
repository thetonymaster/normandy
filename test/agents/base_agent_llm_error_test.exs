defmodule Normandy.Agents.BaseAgentLLMErrorTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLMError
  alias Normandy.Test.StubClient
  alias Normandy.Test.TelemetryCapture

  # Each converse/7 call is reported to the test process, then errors or raises.
  defp error_client(error),
    do: %StubClient{notify: self(), reply: fn _ -> {:error, error} end}

  defp raising_client,
    do: %StubClient{notify: self(), reply: fn _ -> raise ArgumentError, "transport blew up" end}

  defp agent(client, extra \\ %{}) do
    BaseAgent.init(
      Map.merge(%{client: client, model: "claude-opus-5-5", temperature: nil}, extra)
    )
  end

  defp input, do: %Normandy.Agents.BaseAgentInputSchema{chat_message: "hi"}

  defp calls do
    receive do
      {:converse, _, _} -> 1 + calls()
    after
      0 -> 0
    end
  end

  @retry [max_attempts: 3, base_delay: 10, max_delay: 20]

  test "without retry an LLM error raises on the first call" do
    e = LLMError.new(type: :server, status: 500, retryable?: true)
    agent = agent(error_client(e))

    assert_raise LLMError, "LLM call failed: server (500)", fn ->
      BaseAgent.run!(agent, input())
    end

    assert calls() == 1
  end

  test "a retryable error is attempted max_attempts times, then raised" do
    e = LLMError.new(type: :overloaded, status: 529, retryable?: true)
    agent = agent(error_client(e), %{retry: @retry})

    raised = assert_raise LLMError, fn -> BaseAgent.run!(agent, input()) end
    assert raised == e
    assert calls() == 3
  end

  test "llm_call :exception reason carries the usage paid before the failure" do
    # The non-streaming llm_call span runs in the calling process, so a handler
    # running in any other process belongs to a concurrent test.
    test_pid = self()

    ref =
      TelemetryCapture.attach([[:normandy, :agent, :llm_call, :exception]], fn _meta ->
        self() == test_pid
      end)

    e =
      LLMError.with_usage(
        LLMError.new(type: :invalid_output, retryable?: false),
        %{input_tokens: 30, output_tokens: 6}
      )

    assert_raise LLMError, fn -> BaseAgent.run!(agent(error_client(e)), input()) end

    assert_received {:telemetry, ^ref, _, %{reason: %LLMError{} = reason}}
    assert reason.usage == %{input_tokens: 30, output_tokens: 6}
    assert reason.usage_counts == %{input_tokens: 30, output_tokens: 6}
  end

  test "a non-retryable error is attempted once, then raised" do
    e = LLMError.new(type: :authentication, status: 401, retryable?: false)
    agent = agent(error_client(e), %{retry: @retry})

    assert_raise LLMError, ~r/authentication \(401\)/, fn -> BaseAgent.run!(agent, input()) end
    assert calls() == 1
  end

  test "custom retry_if receives the LLMError" do
    test_pid = self()
    e = LLMError.new(type: :rate_limit, status: 429, retryable?: true)

    retry_if = fn term ->
      send(test_pid, {:retry_if_got, term})
      false
    end

    agent =
      agent(error_client(e), %{
        retry: Keyword.put(@retry, :retry_if, retry_if)
      })

    assert_raise LLMError, fn -> BaseAgent.run!(agent, input()) end
    assert_received {:retry_if_got, {:error, ^e}}
    assert calls() == 1
  end

  test "a custom retry_if that refuses an exception re-raises the original exception" do
    agent =
      agent(raising_client(), %{
        retry: Keyword.put(@retry, :retry_if, fn _ -> false end)
      })

    assert_raise ArgumentError, "transport blew up", fn -> BaseAgent.run!(agent, input()) end
    assert calls() == 1
  end

  test "an exception under the circuit breaker (no retry) is re-raised with its original type" do
    agent =
      agent(raising_client(), %{
        circuit_breaker: [scope: {__MODULE__, System.unique_integer([:positive])}]
      })

    assert_raise ArgumentError, "transport blew up", fn -> BaseAgent.run!(agent, input()) end
    assert calls() == 1
  end

  test "a third-party {:error, term} raises ArgumentError keeping the term out of the message" do
    agent = agent(error_client("sk-ant-canary detail"))

    raised = assert_raise ArgumentError, fn -> BaseAgent.run!(agent, input()) end
    assert raised.message =~ "{:error, %Normandy.LLMError{}}"
    assert raised.message =~ "got: {:error, a string"
    refute raised.message =~ "sk-ant-canary"
  end

  test "repeated failures open the circuit breaker, then calls raise :circuit_open" do
    e = LLMError.new(type: :server, status: 503, retryable?: true)

    agent =
      agent(error_client(e), %{
        circuit_breaker: [
          failure_threshold: 2,
          timeout: 60_000,
          scope: {__MODULE__, System.unique_integer([:positive])}
        ]
      })

    assert_raise LLMError, ~r/server/, fn -> BaseAgent.run!(agent, input()) end
    assert_raise LLMError, ~r/server/, fn -> BaseAgent.run!(agent, input()) end

    raised = assert_raise LLMError, fn -> BaseAgent.run!(agent, input()) end
    assert raised.type == :circuit_open
    assert calls() == 2
  end
end
