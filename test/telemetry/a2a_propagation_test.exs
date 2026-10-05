defmodule NormandyTest.Telemetry.A2APropagationTest do
  @moduledoc """
  W3C trace context across an A2A call: `AgentTool` injects `traceparent` into
  the request headers, `A2A.Server.handle_message/3` extracts it, so the remote
  agent's spans join the caller's trace. `:telemetry` handlers and the OTel
  exporter are global, so this is not async.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Claudio.A2A.{AgentCard, Message, Part}
  alias Normandy.A2A.{AgentTool, Server}
  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.OtelSpanBridge
  alias Normandy.Tool
  alias Normandy.Tools.Context

  @trace_id 0x0AF7651916CD43DD8448EB211C80319C
  @parent_span_id 0xB7AD6B7169203331
  @traceparent "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  setup do
    OtelSpanBridge.attach(
      prefixes: OtelSpanBridge.default_prefixes() ++ [[:normandy, :a2a, :request]]
    )

    on_exit(&OtelSpanBridge.detach/0)
    {:ok, bypass: Bypass.open()}
  end

  defp remote_agent do
    BaseAgent.init(%{
      client: %Normandy.Test.TaggingClient{name: "remote"},
      model: "test-model",
      name: "remote-agent"
    })
  end

  # A Bypass endpoint that serves A2A `message/send` with `Server.handle_message/3`,
  # passing the request headers as the carrier, and reports them to `test_pid`.
  defp serve_a2a(bypass, test_pid) do
    Bypass.expect_once(bypass, "POST", "/a2a", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test_pid, {:request_headers, conn.req_headers})

      message = Message.from_map(request["params"]["message"])
      {:ok, task} = Server.handle_message(remote_agent(), message, conn.req_headers)

      response =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => Claudio.A2A.Task.to_map(task)
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, response)
    end)
  end

  defp agent_tool(bypass, opts \\ []) do
    AgentTool.new(
      "http://localhost:#{bypass.port}/a2a",
      AgentCard.new("remote", "a remote agent"),
      opts
    )
  end

  defp run(tool), do: Tool.run(tool, %Context{tool_call_id: "t", input: %{"message" => "hi"}})

  defp with_caller_span(fun) do
    tracer = :opentelemetry.get_application_tracer(__MODULE__)
    caller = :otel_tracer.start_span(:otel_ctx.get_current(), tracer, "caller", %{})
    token = :otel_ctx.attach(:otel_tracer.set_current_span(:otel_ctx.get_current(), caller))

    try do
      fun.()
    after
      :otel_span.end_span(caller)
      :otel_ctx.detach(token)
    end
  end

  describe "AgentTool -> A2A.Server round trip" do
    test "the remote agent's spans join the caller's trace", %{bypass: bypass} do
      serve_a2a(bypass, self())

      assert {:ok, _text} = with_caller_span(fn -> run(agent_tool(bypass)) end)

      spans =
        OtelSpanBridge.await_spans([
          "caller",
          "normandy.a2a.request",
          "normandy.agent.run",
          "normandy.agent.llm_call"
        ])

      caller = OtelSpanBridge.fetch_span!(spans, "caller")
      request = OtelSpanBridge.fetch_span!(spans, "normandy.a2a.request")
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")

      assert request.parent_span_id == caller.span_id
      assert run.parent_span_id == request.span_id
      assert spans |> Enum.map(& &1.trace_id) |> Enum.uniq() == [caller.trace_id]
    end

    test "keeps the caller's own transport headers beside the trace headers", %{bypass: bypass} do
      serve_a2a(bypass, self())
      tool = agent_tool(bypass, transport_opts: [headers: [{"x-tenant", "t1"}]])

      assert {:ok, _text} = with_caller_span(fn -> run(tool) end)

      assert_received {:request_headers, headers}
      assert {"x-tenant", "t1"} in headers
      assert List.keymember?(headers, "traceparent", 0)
    end

    test "accepts map transport headers under an active span", %{bypass: bypass} do
      serve_a2a(bypass, self())
      tool = agent_tool(bypass, transport_opts: [headers: %{"x-tenant" => "t1"}])

      assert {:ok, _text} = with_caller_span(fn -> run(tool) end)

      assert_received {:request_headers, headers}
      assert {"x-tenant", "t1"} in headers
      assert List.keymember?(headers, "traceparent", 0)
    end

    test "sends no traceparent without an active span", %{bypass: bypass} do
      serve_a2a(bypass, self())

      assert {:ok, _text} = run(agent_tool(bypass))

      assert_received {:request_headers, headers}
      refute List.keymember?(headers, "traceparent", 0)
    end
  end

  describe "A2A.Server.handle_message/3" do
    test "parents the request span on the carrier's span and restores the context" do
      before = :otel_ctx.get_current()
      message = Message.new(:user, [Part.text("hi")])

      assert {:ok, _task} =
               Server.handle_message(remote_agent(), message, [{"traceparent", @traceparent}])

      assert :otel_ctx.get_current() == before

      spans =
        OtelSpanBridge.await_spans([
          "normandy.a2a.request",
          "normandy.agent.run",
          "normandy.agent.llm_call"
        ])

      request = OtelSpanBridge.fetch_span!(spans, "normandy.a2a.request")
      assert request.trace_id == @trace_id
      assert request.parent_span_id == @parent_span_id
    end

    test "a carrier without traceparent keeps the current context as parent" do
      message = Message.new(:user, [Part.text("hi")])

      with_caller_span(fn ->
        assert {:ok, _task} =
                 Server.handle_message(remote_agent(), message, [{"x-tenant", "t1"}])
      end)

      spans = OtelSpanBridge.await_spans(["caller", "normandy.a2a.request"])
      caller = OtelSpanBridge.fetch_span!(spans, "caller")
      request = OtelSpanBridge.fetch_span!(spans, "normandy.a2a.request")
      assert request.parent_span_id == caller.span_id
    end

    test "a malformed traceparent keeps the current context as parent" do
      message = Message.new(:user, [Part.text("hi")])

      with_caller_span(fn ->
        assert {:ok, _task} =
                 Server.handle_message(remote_agent(), message, [{"traceparent", "garbage"}])
      end)

      spans = OtelSpanBridge.await_spans(["caller", "normandy.a2a.request"])
      caller = OtelSpanBridge.fetch_span!(spans, "caller")
      request = OtelSpanBridge.fetch_span!(spans, "normandy.a2a.request")
      assert request.parent_span_id == caller.span_id
    end

    test "accepts atom header names" do
      message = Message.new(:user, [Part.text("hi")])

      assert {:ok, _task} =
               Server.handle_message(remote_agent(), message, [
                 {:"x-tenant", "t1"},
                 {:traceparent, @traceparent}
               ])

      spans = OtelSpanBridge.await_spans(["normandy.a2a.request"])
      request = OtelSpanBridge.fetch_span!(spans, "normandy.a2a.request")
      assert request.trace_id == @trace_id
      assert request.parent_span_id == @parent_span_id
    end
  end

  def handle_request(event, _measurements, metadata, test_pid),
    do: send(test_pid, {event, metadata})

  describe "[:normandy, :a2a, :request] telemetry" do
    setup do
      test_pid = self()
      handler_id = "a2a-request-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler_id,
          [[:normandy, :a2a, :request, :start], [:normandy, :a2a, :request, :stop]],
          &__MODULE__.handle_request/4,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "carries task_id and agent_name, never the message text" do
      message = Message.new(:user, [Part.text("secret prompt")])
      assert {:ok, task} = Server.handle_message(remote_agent(), message)

      assert_received {[:normandy, :a2a, :request, :start], start}
      assert_received {[:normandy, :a2a, :request, :stop], stop}

      assert %{task_id: task_id, agent_name: "remote-agent"} = start
      assert task_id == task.id
      assert %{task_id: ^task_id, agent_name: "remote-agent", status: :ok} = stop

      for metadata <- [start, stop] do
        refute inspect(Map.drop(metadata, [:telemetry_span_context])) =~ "secret prompt"
      end
    end

    test "a failed request stops with status :error and the reason" do
      message = Message.new(:user, [Part.text("")])
      assert {:error, :no_text} = Server.handle_message(remote_agent(), message)

      assert_received {[:normandy, :a2a, :request, :stop], stop}
      assert %{status: :error, error_type: :no_text} = stop
    end
  end
end
