defmodule NormandyTest.Telemetry.SpanHierarchyTest do
  @moduledoc """
  Asserts the OTel parent/child structure that telemetry-bridged spans form.
  `:telemetry` handlers and the OTel exporter are global, so this is not async.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, ToolCallResponse, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.ToolCall
  alias Normandy.Test.{FakeTool, OtelSpanBridge, StubClient}
  alias Normandy.Tools.Registry

  setup do
    OtelSpanBridge.attach()

    on_exit(&OtelSpanBridge.detach/0)
  end

  defp tool_then_final_client do
    reply = fn _response_model, _opts ->
      # `converse/7` gets no history here; a counter distinguishes the two calls.
      n = Process.get(:converse_calls, 0)
      Process.put(:converse_calls, n + 1)

      if n == 0 do
        %ToolCallResponse{
          content: nil,
          tool_calls: [%ToolCall{id: "call_1", name: "weather", input: %{city: "Lima"}}]
        }
      else
        %ToolCallResponse{content: "done", tool_calls: []}
      end
    end

    %StubClient{reply: reply}
  end

  describe "BaseAgent.run/2" do
    test "nests run under the caller, and llm_call and tool under run" do
      agent =
        BaseAgent.init(%{
          client: tool_then_final_client(),
          model: "test-model",
          tool_registry: Registry.new([%FakeTool{}])
        })

      tracer = :opentelemetry.get_application_tracer(__MODULE__)
      caller = :otel_tracer.start_span(:otel_ctx.get_current(), tracer, "caller", %{})
      OpenTelemetry.Ctx.attach(:otel_tracer.set_current_span(:otel_ctx.get_current(), caller))

      {_agent, _response} = BaseAgent.run(agent, %{chat_message: "hi"})

      :otel_span.end_span(caller)

      spans =
        OtelSpanBridge.await_spans([
          "caller",
          "normandy.agent.run",
          "normandy.tool.execute",
          "normandy.agent.llm_call",
          "normandy.agent.llm_call"
        ])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")
      tool = OtelSpanBridge.fetch_span!(spans, "normandy.tool.execute")
      llm_calls = Enum.filter(spans, &(&1.name == "normandy.agent.llm_call"))

      assert [_, _] = llm_calls
      assert run.parent_span_id == caller_span.span_id
      assert tool.parent_span_id == run.span_id
      assert Enum.all?(llm_calls, &(&1.parent_span_id == run.span_id))
      assert spans |> Enum.map(& &1.trace_id) |> Enum.uniq() == [caller_span.trace_id]
    end
  end

  # Turn.Server runs each LLM call in its own worker process, so the reply switches
  # on a shared counter rather than the process dictionary.
  defp counted_client(tool_first?) do
    counter = :counters.new(1, [])

    reply = fn _response_model, _opts ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      if tool_first? and n == 0 do
        %ToolCallResponse{
          content: nil,
          tool_calls: [%ToolCall{id: "call_1", name: "weather", input: %{city: "Lima"}}]
        }
      else
        %ToolCallResponse{content: "done", tool_calls: []}
      end
    end

    %StubClient{reply: reply}
  end

  defp start_turn_server(client) do
    config =
      BaseAgent.init(%{
        client: client,
        model: "test-model",
        tool_registry: Registry.new([%FakeTool{}])
      })

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "span-#{System.unique_integer([:positive])}",
        config: config,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    srv
  end

  # Opens a "caller" span and makes it current in the test process.
  defp start_caller_span do
    tracer = :opentelemetry.get_application_tracer(__MODULE__)
    caller = :otel_tracer.start_span(:otel_ctx.get_current(), tracer, "caller", %{})
    OpenTelemetry.Ctx.attach(:otel_tracer.set_current_span(:otel_ctx.get_current(), caller))
    caller
  end

  describe "Turn.Server.run/2" do
    test "nests run under the caller, and llm_call under run" do
      srv = start_turn_server(counted_client(false))
      caller = start_caller_span()

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})

      :otel_span.end_span(caller)

      spans =
        OtelSpanBridge.await_spans(["caller", "normandy.agent.run", "normandy.agent.llm_call"])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")
      llm_call = OtelSpanBridge.fetch_span!(spans, "normandy.agent.llm_call")

      assert run.parent_span_id == caller_span.span_id
      assert llm_call.parent_span_id == run.span_id
      assert spans |> Enum.map(& &1.trace_id) |> Enum.uniq() == [caller_span.trace_id]
    end

    test "nests tool execution under run" do
      srv = start_turn_server(counted_client(true))
      caller = start_caller_span()

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})

      :otel_span.end_span(caller)

      spans =
        OtelSpanBridge.await_spans([
          "caller",
          "normandy.agent.run",
          "normandy.tool.execute",
          "normandy.agent.llm_call",
          "normandy.agent.llm_call"
        ])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")
      tool = OtelSpanBridge.fetch_span!(spans, "normandy.tool.execute")
      llm_calls = Enum.filter(spans, &(&1.name == "normandy.agent.llm_call"))

      assert run.parent_span_id == caller_span.span_id
      assert tool.parent_span_id == run.span_id
      assert Enum.all?(llm_calls, &(&1.parent_span_id == run.span_id))
      assert spans |> Enum.map(& &1.trace_id) |> Enum.uniq() == [caller_span.trace_id]
    end

    # The two-element request carries no caller context; the run span is a root.
    # It also proves the first turn's caller context was detached afterwards.
    test "does not carry one turn's caller context into the next" do
      srv = start_turn_server(counted_client(false))
      caller = start_caller_span()

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})

      :otel_span.end_span(caller)
      first = OtelSpanBridge.await_spans(["caller", "normandy.agent.run"])
      caller_span = OtelSpanBridge.fetch_span!(first, "caller")

      assert {:ok, _} = :gen_statem.call(srv, {:turn, %{chat_message: "again"}}, :infinity)

      spans = OtelSpanBridge.await_spans(["normandy.agent.run"])
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")

      assert run.parent_span_id == :undefined
      refute run.trace_id == caller_span.trace_id
    end
  end
end
