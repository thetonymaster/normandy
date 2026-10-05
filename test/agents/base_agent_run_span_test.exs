defmodule NormandyTest.Agents.BaseAgentRunSpanTest do
  @moduledoc """
  Locks in the contract: EXACTLY ONE `[:normandy, :agent, :run]` span is emitted
  per agent invocation, regardless of which public entry point is used
  (`run/2`, `run!/2` or `stream/3`, with or without tools).

  Downstream OTel consumers map this span to the GenAI semantic-convention
  `gen_ai.operation.name = "invoke_agent"`. A missing span drops `invoke_agent`
  from traces; a duplicated
  span (double-wrap) corrupts agent timing. Both failure modes are asserted here.

  `:telemetry` handlers are global, so each run gets an agent name no other
  test uses and the handler counts only that agent's spans; the exact-count
  assertions then hold while other tests run concurrently.
  """
  use ExUnit.Case, async: true

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
      def converse(config, _request, _opts) do
        {:ok,
         %Normandy.LLM.Response{
           content: %Normandy.Agents.ToolCallResponse{
             content: config.final_response,
             tool_calls: []
           }
         }}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  # Minimal streaming client so `stream/3` drives a stream
  # to a clean stop. Event sequence mirrors the proven mock in
  # base_agent_streaming_test.exs.
  defmodule StreamingClient do
    use Normandy.Schema

    schema do
      field(:key, :string, default: "stuff")
    end

    defimpl Normandy.Agents.Model do
      def converse(_client, request, _opts),
        do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

      def stream(_client, _request, _opts) do
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

        {:ok, Stream.map(events, & &1)}
      end
    end
  end

  def handle_span(event, _measurements, metadata, {parent, name, ref}) do
    if metadata[:agent_name] == name, do: send(parent, {ref, event})
  end

  # Runs `fun` on `agent` (renamed uniquely) with a temporary handler forwarding
  # that agent's `agent.run` start/stop to the test process, then asserts EXACTLY
  # ONE of each was emitted. The run is synchronous, so by the time `fun` returns
  # every span event is already in the mailbox. Detaches in `after` so a failing
  # assertion still removes the global handler.
  defp assert_exactly_one_run_span(agent, fun) do
    handler_id = "run-span-count-#{System.unique_integer([:positive])}"
    name = "run-span-#{System.unique_integer([:positive])}"
    parent = self()
    ref = make_ref()

    :telemetry.attach_many(
      handler_id,
      [
        [:normandy, :agent, :run, :start],
        [:normandy, :agent, :run, :stop]
      ],
      &__MODULE__.handle_span/4,
      {parent, name, ref}
    )

    try do
      fun.(%{agent | name: name})
    after
      :telemetry.detach(handler_id)
    end

    assert_receive {^ref, [:normandy, :agent, :run, :start]}
    refute_receive {^ref, [:normandy, :agent, :run, :start]}

    assert_receive {^ref, [:normandy, :agent, :run, :stop]}
    refute_receive {^ref, [:normandy, :agent, :run, :stop]}
  end

  test "run!/2 without tools emits exactly one agent.run span" do
    agent =
      BaseAgent.init(%{
        client: %NormandyTest.Support.ModelMockup{},
        model: "claude-haiku-4-5-20251001",
        temperature: 0.7
      })

    assert_exactly_one_run_span(agent, &BaseAgent.run!(&1, "hello"))
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

    assert_exactly_one_run_span(agent, &BaseAgent.run!(&1, %{chat_message: "hi"}))
  end

  test "stream/3 emits exactly one agent.run span" do
    agent =
      BaseAgent.init(%{
        client: %StreamingClient{},
        model: "claude-3",
        temperature: 0.7
      })

    assert_exactly_one_run_span(agent, fn agent ->
      {:ok, _agent, _response} =
        BaseAgent.stream(agent, %{chat_message: "Hello"}, fn _event -> :ok end)
    end)
  end

  test "stream/3 with a tool registry emits exactly one agent.run span" do
    agent =
      BaseAgent.init(%{
        client: %StreamingClient{},
        model: "claude-3",
        temperature: 0.7,
        tool_registry: Registry.new([%Calculator{operation: "add", a: 0, b: 0}])
      })

    assert_exactly_one_run_span(agent, fn agent ->
      {:ok, _agent, _response} =
        BaseAgent.stream(agent, %{chat_message: "Hello"}, fn _event -> :ok end)
    end)
  end
end
