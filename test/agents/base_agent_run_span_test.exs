defmodule NormandyTest.Agents.BaseAgentRunSpanTest do
  @moduledoc """
  Locks in the contract: EXACTLY ONE `[:normandy, :agent, :run]` span is emitted
  per agent invocation, regardless of which public entry point is used
  (`run/2`, `run/3` streaming, or `run_with_tools/2` directly).

  Downstream OTel consumers map this span to the GenAI semantic-convention
  `gen_ai.operation.name = "invoke_agent"`. A missing span (consumer calls
  `run_with_tools/2` directly) drops `invoke_agent` from traces; a duplicated
  span (double-wrap) corrupts agent timing. Both failure modes are asserted here.

  `async: false` because `:telemetry` handlers are global — a concurrent test
  emitting `[:normandy, :agent, :run]` would contaminate the exact-count
  assertions (the `refute_receive` for a second span).
  """
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Registry

  # Minimal tools-capable client: returns a final response with no tool calls
  # (the idiomatic "I'm done" shape for a tools turn), so a tool registry forces
  # `run/2` down its tools branch without needing an actual tool execution.
  defmodule FinalOnlyToolClient do
    use Normandy.Schema

    schema do
      field(:final_response, :string, default: "done")
    end

    defimpl Normandy.Agents.Model do
      def completitions(_config, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(
            config,
            _model,
            _temperature,
            _max_tokens,
            _messages,
            _response_model,
            _opts \\ []
          ) do
        %Normandy.Agents.ToolCallResponse{content: config.final_response, tool_calls: []}
      end
    end
  end

  # Minimal streaming client so `run/3` (stream: true) drives `stream_response`
  # to a clean stop. Event sequence mirrors the proven mock in
  # base_agent_streaming_test.exs.
  defmodule StreamingClient do
    use Normandy.Schema

    schema do
      field(:key, :string, default: "stuff")
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(_client, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
        response_model
      end

      def stream_converse(_client, _model, _temperature, _max_tokens, _messages, _rm, opts \\ []) do
        callback = Keyword.get(opts, :callback)

        events = [
          %{
            type: "message_start",
            message: %{"id" => "msg_1", "model" => "claude-3", "role" => "assistant"}
          },
          %{
            type: "content_block_start",
            content_block: %{"type" => "text", "text" => ""},
            index: 0
          },
          %{
            type: "content_block_delta",
            delta: %{"type" => "text_delta", "text" => "Hi"},
            index: 0
          },
          %{
            type: "message_delta",
            delta: %{"stop_reason" => "end_turn"},
            usage: %{"output_tokens" => 1}
          },
          %{type: "message_stop"}
        ]

        if callback do
          Enum.each(events, fn
            %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}} ->
              callback.(:text_delta, text)

            %{type: "message_start", message: message} ->
              callback.(:message_start, message)

            %{type: "message_stop"} ->
              callback.(:message_stop, %{})

            _ ->
              :ok
          end)
        end

        {:ok, Stream.map(events, & &1)}
      end
    end
  end

  # Runs `fun` with a temporary handler forwarding every `agent.run` start/stop
  # to the test process, then asserts EXACTLY ONE of each was emitted. The run is
  # synchronous, so by the time `fun` returns every span event is already in the
  # mailbox. Detaches in `after` so a failing assertion still removes the global
  # handler.
  defp assert_exactly_one_run_span(fun) do
    handler_id = "run-span-count-#{System.unique_integer([:positive])}"
    parent = self()
    ref = make_ref()

    :telemetry.attach_many(
      handler_id,
      [
        [:normandy, :agent, :run, :start],
        [:normandy, :agent, :run, :stop]
      ],
      fn event, _measurements, _metadata, _ -> send(parent, {ref, event}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    assert_receive {^ref, [:normandy, :agent, :run, :start]}
    refute_receive {^ref, [:normandy, :agent, :run, :start]}

    assert_receive {^ref, [:normandy, :agent, :run, :stop]}
    refute_receive {^ref, [:normandy, :agent, :run, :stop]}
  end

  test "run_with_tools/2 called directly emits exactly one agent.run span" do
    agent =
      BaseAgent.init(%{
        client: %NormandyTest.Support.ModelMockup{},
        model: "claude-haiku-4-5-20251001",
        temperature: 0.7
      })

    assert_exactly_one_run_span(fn -> BaseAgent.run_with_tools(agent, "hello") end)
  end

  test "run/2 with a tool registry emits exactly one agent.run span (no double-wrap)" do
    agent =
      BaseAgent.init(%{
        client: %FinalOnlyToolClient{},
        model: "test-model",
        temperature: 0.7,
        tool_registry: Registry.new([%Calculator{operation: "add", a: 0, b: 0}]),
        max_tool_iterations: 5
      })

    assert_exactly_one_run_span(fn -> BaseAgent.run(agent, %{text: "hi"}) end)
  end

  test "run/3 streaming emits exactly one agent.run span" do
    agent =
      BaseAgent.init(%{
        client: %StreamingClient{},
        model: "claude-3",
        temperature: 0.7
      })

    callback = fn _type, _payload -> :ok end

    assert_exactly_one_run_span(fn ->
      BaseAgent.run(agent, %{chat_message: "Hello"}, stream: true, on_chunk: callback)
    end)
  end
end
