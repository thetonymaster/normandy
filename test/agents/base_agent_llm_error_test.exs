defmodule Normandy.Agents.BaseAgentLLMErrorTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLMError

  # Returns {:error, error} from converse/7 and reports each call to `notify`.
  defmodule ErrorClient do
    defstruct notify: nil, error: nil
  end

  defimpl Normandy.Agents.Model, for: Normandy.Agents.BaseAgentLLMErrorTest.ErrorClient do
    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

    def converse(client, _m, _t, _mt, _msgs, _response_model, _opts) do
      send(client.notify, :converse_called)
      {:error, client.error}
    end
  end

  # Raises from converse/7.
  defmodule RaisingClient do
    defstruct notify: nil
  end

  defimpl Normandy.Agents.Model, for: Normandy.Agents.BaseAgentLLMErrorTest.RaisingClient do
    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

    def converse(client, _m, _t, _mt, _msgs, _response_model, _opts) do
      send(client.notify, :converse_called)
      raise ArgumentError, "transport blew up"
    end
  end

  defp agent(client, extra \\ %{}) do
    BaseAgent.init(
      Map.merge(%{client: client, model: "claude-opus-5-5", temperature: nil}, extra)
    )
  end

  defp input, do: %Normandy.Agents.BaseAgentInputSchema{chat_message: "hi"}

  defp calls do
    receive do
      :converse_called -> 1 + calls()
    after
      0 -> 0
    end
  end

  @retry [max_attempts: 3, base_delay: 10, max_delay: 20]

  test "without retry_options an LLM error raises on the first call" do
    e = LLMError.new(type: :server, status: 500, retryable?: true)
    agent = agent(%ErrorClient{notify: self(), error: e})

    assert_raise LLMError, "LLM call failed: server (500)", fn ->
      BaseAgent.run(agent, input())
    end

    assert calls() == 1
  end

  test "a retryable error is attempted max_attempts times, then raised" do
    e = LLMError.new(type: :overloaded, status: 529, retryable?: true)
    agent = agent(%ErrorClient{notify: self(), error: e}, %{retry_options: @retry})

    raised = assert_raise LLMError, fn -> BaseAgent.run(agent, input()) end
    assert raised == e
    assert calls() == 3
  end

  test "a non-retryable error is attempted once, then raised" do
    e = LLMError.new(type: :authentication, status: 401, retryable?: false)
    agent = agent(%ErrorClient{notify: self(), error: e}, %{retry_options: @retry})

    assert_raise LLMError, ~r/authentication \(401\)/, fn -> BaseAgent.run(agent, input()) end
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
      agent(%ErrorClient{notify: self(), error: e}, %{
        retry_options: Keyword.put(@retry, :retry_if, retry_if)
      })

    assert_raise LLMError, fn -> BaseAgent.run(agent, input()) end
    assert_received {:retry_if_got, {:error, ^e}}
  end

  test "a custom retry_if that refuses an exception re-raises the original exception" do
    agent =
      agent(%RaisingClient{notify: self()}, %{
        retry_options: Keyword.put(@retry, :retry_if, fn _ -> false end)
      })

    assert_raise ArgumentError, "transport blew up", fn -> BaseAgent.run(agent, input()) end
    assert calls() == 1
  end

  test "an exception under the circuit breaker (no retry) is re-raised with its original type" do
    agent = agent(%RaisingClient{notify: self()}, %{enable_circuit_breaker: true})

    assert_raise ArgumentError, "transport blew up", fn -> BaseAgent.run(agent, input()) end
    assert calls() == 1
  end

  test "a third-party {:error, term} raises an :unknown LLMError keeping the term out of the message" do
    agent = agent(%ErrorClient{notify: self(), error: "sk-ant-canary detail"})

    raised = assert_raise LLMError, fn -> BaseAgent.run(agent, input()) end
    assert raised.type == :unknown
    assert raised.reason == "sk-ant-canary detail"
    refute raised.message =~ "sk-ant-canary"
  end

  test "repeated failures open the circuit breaker, then calls raise :circuit_open" do
    e = LLMError.new(type: :server, status: 503, retryable?: true)

    agent =
      agent(%ErrorClient{notify: self(), error: e}, %{
        enable_circuit_breaker: true,
        circuit_breaker_options: [failure_threshold: 2, timeout: 60_000]
      })

    assert_raise LLMError, ~r/server/, fn -> BaseAgent.run(agent, input()) end
    assert_raise LLMError, ~r/server/, fn -> BaseAgent.run(agent, input()) end

    raised = assert_raise LLMError, fn -> BaseAgent.run(agent, input()) end
    assert raised.type == :circuit_open
    assert calls() == 2
  end
end
