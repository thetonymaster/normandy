defmodule Normandy.Agents.BaseAgentTaskBudgetTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn

  defmodule OptsClient do
    defstruct notify: nil, options: %{}
  end

  defimpl Normandy.Agents.Model, for: Normandy.Agents.BaseAgentTaskBudgetTest.OptsClient do
    def converse(client, request, _opts) do
      send(client.notify, {:converse_request, request})
      {:ok, %Normandy.LLM.Response{content: request.response_model}}
    end

    def stream(client, request, _opts) do
      send(client.notify, {:stream_request, request})

      {:error,
       Normandy.LLMError.new(type: :unknown, retryable?: false, reason: :stop_after_capture)}
    end
  end

  defp config(options) do
    BaseAgent.init(%{
      client: %OptsClient{notify: self(), options: options},
      model: "claude-opus-5-5",
      temperature: nil
    })
  end

  defp state(compacted),
    do: %Turn.State{status: :assistant_streaming, tokens_compacted: compacted}

  defp non_streaming_call(config, state) do
    BaseAgent.non_streaming_handlers().call_llm.(config, state, %{
      response_model: config.output_schema
    })

    assert_received {:converse_request, request}
    request.task_budget_remaining
  end

  defp streaming_call(config, state) do
    handlers = BaseAgent.streaming_handlers(fn _event -> :ok end)

    {:stream_turn_error, %Normandy.LLMError{reason: :stop_after_capture}} =
      catch_throw(handlers.call_llm.(config, state, %{response_model: config.output_schema}))

    assert_received {:stream_request, request}
    request.task_budget_remaining
  end

  test "before any compaction no remaining is sent (the server tracks the countdown)" do
    assert non_streaming_call(config(%{task_budget: 64_000}), state(0)) == nil
  end

  test "after compaction remaining = total - tokens_compacted" do
    assert non_streaming_call(config(%{task_budget: 64_000}), state(30_000)) == 34_000
  end

  test "remaining never goes below zero" do
    assert non_streaming_call(config(%{task_budget: 64_000}), state(70_000)) == 0
  end

  test "without a task_budget nothing is sent, even after compaction" do
    assert non_streaming_call(config(%{}), state(30_000)) == nil
  end

  test "a Turn.State persisted before 2.0 (no :tokens_compacted) is treated as never compacted" do
    old_state = Map.delete(state(0), :tokens_compacted)
    assert non_streaming_call(config(%{task_budget: 64_000}), old_state) == nil
  end

  test "the streaming handler sends the same sticky remaining" do
    assert streaming_call(config(%{task_budget: 64_000}), state(30_000)) == 34_000
  end
end
