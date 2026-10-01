defmodule Normandy.Agents.BaseAgentTaskBudgetTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn

  defmodule OptsClient do
    defstruct notify: nil, options: %{}
  end

  defimpl Normandy.Agents.Model, for: Normandy.Agents.BaseAgentTaskBudgetTest.OptsClient do
    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

    def converse(client, _m, _t, _mt, _msgs, response_model, opts) do
      send(client.notify, {:converse_opts, opts})
      response_model
    end

    def stream_converse(client, _m, _t, _mt, _msgs, _response_model, opts) do
      send(client.notify, {:stream_opts, opts})
      {:error, :stop_after_capture}
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

    assert_received {:converse_opts, opts}
    opts
  end

  defp streaming_call(config, state) do
    handlers = BaseAgent.streaming_handlers(fn _event, _data -> :ok end)

    {:stream_turn_error, :stop_after_capture, _config} =
      catch_throw(handlers.call_llm.(config, state, %{response_model: config.output_schema}))

    assert_received {:stream_opts, opts}
    opts
  end

  test "before any compaction no remaining is sent (the server tracks the countdown)" do
    opts = non_streaming_call(config(%{task_budget: 64_000}), state(0))
    refute Keyword.has_key?(opts, :task_budget_remaining)
  end

  test "after compaction remaining = total - tokens_compacted" do
    opts = non_streaming_call(config(%{task_budget: 64_000}), state(30_000))
    assert opts[:task_budget_remaining] == 34_000
  end

  test "remaining never goes below zero" do
    opts = non_streaming_call(config(%{task_budget: 64_000}), state(70_000))
    assert opts[:task_budget_remaining] == 0
  end

  test "without a task_budget nothing is sent, even after compaction" do
    opts = non_streaming_call(config(%{}), state(30_000))
    refute Keyword.has_key?(opts, :task_budget_remaining)
  end

  test "a Turn.State persisted before 2.0 (no :tokens_compacted) is treated as never compacted" do
    old_state = Map.delete(state(0), :tokens_compacted)
    opts = non_streaming_call(config(%{task_budget: 64_000}), old_state)
    refute Keyword.has_key?(opts, :task_budget_remaining)
  end

  test "the streaming handler sends the same sticky remaining" do
    opts = streaming_call(config(%{task_budget: 64_000}), state(30_000))
    assert opts[:task_budget_remaining] == 34_000
  end
end
