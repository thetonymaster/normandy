defmodule Normandy.Agents.BaseAgentStreamResilienceTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLMError

  @moduletag :capture_log

  # Fails its first `fail_times` streams with a retryable error, optionally after
  # sending one event to the callback (as an adapter does mid-stream), then
  # streams a short text answer. `attempts` is an Agent counting calls.
  defmodule FlakyStreamClient do
    defstruct [:attempts, fail_times: 0, deliver_before_fail: false]
  end

  defimpl Normandy.Agents.Model,
    for: Normandy.Agents.BaseAgentStreamResilienceTest.FlakyStreamClient do
    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model
    def converse(_c, _m, _t, _mt, _msgs, response_model, _opts), do: response_model

    def stream_converse(client, _m, _t, _mt, _msgs, _rm, opts) do
      n = Agent.get_and_update(client.attempts, &{&1 + 1, &1 + 1})

      if n <= client.fail_times do
        if client.deliver_before_fail, do: opts[:callback].(:text_delta, "part")
        {:error, LLMError.new(type: :overloaded, retryable?: true, status: 529)}
      else
        {:ok,
         [
           %{type: "message_start", message: %{"id" => "m", "role" => "assistant"}},
           %{
             type: "content_block_start",
             content_block: %{"type" => "text", "text" => ""},
             index: 0
           },
           %{
             type: "content_block_delta",
             delta: %{"type" => "text_delta", "text" => "ok"},
             index: 0
           },
           %{type: "message_stop"}
         ]}
      end
    end
  end

  defp agent(client_fields, config) do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    client = struct(FlakyStreamClient, [attempts: attempts] ++ client_fields)
    {BaseAgent.init(Map.merge(%{client: client, model: "claude-opus-5-5"}, config)), attempts}
  end

  defp stream(agent), do: BaseAgent.stream_response(agent, "hi", fn _, _ -> :ok end)
  defp attempts(counter), do: Agent.get(counter, & &1)

  @retry %{retry_options: [max_attempts: 3, base_delay: 1, max_delay: 2, jitter: false]}

  test "a stream that fails before any event is retried under retry_options" do
    {agent, counter} = agent([fail_times: 2], @retry)

    assert {_config, _response} = stream(agent)
    assert attempts(counter) == 3
  end

  test "a stream that fails after an event reached the callback is not retried" do
    {agent, counter} = agent([fail_times: 1, deliver_before_fail: true], @retry)

    assert_raise LLMError, fn -> stream(agent) end
    assert attempts(counter) == 1
  end

  test "stream failures count toward the circuit breaker" do
    {agent, counter} =
      agent([fail_times: 10], %{
        enable_circuit_breaker: true,
        circuit_breaker_options: [failure_threshold: 1, timeout: 60_000]
      })

    assert_raise LLMError, fn -> stream(agent) end

    error = assert_raise LLMError, fn -> stream(agent) end
    assert error.type == :circuit_open
    assert attempts(counter) == 1
  end
end
