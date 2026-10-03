defmodule NormandyTest.Telemetry.SpanHierarchyTest do
  @moduledoc """
  Asserts the OTel parent/child structure that telemetry-bridged spans form.
  `:telemetry` handlers and the OTel exporter are global, so this is not async.
  """
  use ExUnit.Case, async: false

  alias Normandy.Agents.{BaseAgent, ToolCallResponse}
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
end
