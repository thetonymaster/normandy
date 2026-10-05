defmodule Normandy.Agents.BaseAgentStreamResilienceTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLMError

  @moduletag :capture_log

  # Fails its first `fail_times` streams with a retryable error, then streams a short
  # text answer. With `deliver_before_fail`, a failing stream first yields a text delta
  # (which Normandy delivers to the callback) and then raises the retryable error
  # mid-stream. `attempts` is an Agent counting calls.
  defmodule FlakyStreamClient do
    defstruct [:attempts, fail_times: 0, deliver_before_fail: false]
  end

  defimpl Normandy.Agents.Model,
    for: Normandy.Agents.BaseAgentStreamResilienceTest.FlakyStreamClient do
    def converse(_c, request, _opts),
      do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

    def stream(client, _request, _opts) do
      n = Agent.get_and_update(client.attempts, &{&1 + 1, &1 + 1})
      overloaded = LLMError.new(type: :overloaded, retryable?: true, status: 529)

      cond do
        n <= client.fail_times and client.deliver_before_fail ->
          {:ok,
           Stream.concat(
             [
               %{
                 type: "content_block_delta",
                 delta: %{"type" => "text_delta", "text" => "part"},
                 index: 0
               }
             ],
             Stream.map([:fail], fn :fail -> raise overloaded end)
           )}

        n <= client.fail_times ->
          {:error, overloaded}

        true ->
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

  defp stream(agent), do: BaseAgent.stream(agent, "hi", fn _event -> :ok end)
  defp attempts(counter), do: Agent.get(counter, & &1)

  @retry %{retry: [max_attempts: 3, base_delay: 1, max_delay: 2, jitter: false]}

  test "a stream that fails before any event is retried under retry" do
    {agent, counter} = agent([fail_times: 2], @retry)

    assert {:ok, _config, _response} = stream(agent)
    assert attempts(counter) == 3
  end

  test "a stream that fails after an event reached the callback is not retried" do
    {agent, counter} = agent([fail_times: 1, deliver_before_fail: true], @retry)

    assert {:error, %LLMError{type: :overloaded}} = stream(agent)
    assert attempts(counter) == 1
  end

  test "stream failures count toward the circuit breaker" do
    {agent, counter} =
      agent([fail_times: 10], %{
        circuit_breaker: [failure_threshold: 1, timeout: 60_000]
      })

    assert {:error, %LLMError{}} = stream(agent)

    assert {:error, %LLMError{type: :circuit_open}} = stream(agent)
    assert attempts(counter) == 1
  end
end
