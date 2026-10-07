defmodule NormandyTest.Telemetry.SpanHierarchyTest do
  @moduledoc """
  Asserts the OTel parent/child structure that telemetry-bridged spans form.
  `:telemetry` handlers and the OTel exporter are global, so this is not async.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, ToolCallResponse, Turn}
  alias Normandy.Batch.Processor
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.ToolCall

  alias Normandy.Coordination.{
    AgentProcess,
    ParallelOrchestrator,
    Reactive,
    SequentialOrchestrator
  }

  alias Normandy.Test.{FakeTool, FlakyStore, OtelSpanBridge, StubClient}
  alias Normandy.Tools.Toolset

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
          toolset: Toolset.new([%FakeTool{}])
        })

      tracer = :opentelemetry.get_application_tracer(__MODULE__)
      caller = :otel_tracer.start_span(:otel_ctx.get_current(), tracer, "caller", %{})
      OpenTelemetry.Ctx.attach(:otel_tracer.set_current_span(:otel_ctx.get_current(), caller))

      {_agent, _response} = BaseAgent.run!(agent, %{chat_message: "hi"})

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

  describe "LLM requests" do
    test "a retried llm_call nests one request span per provider request" do
      OtelSpanBridge.attach(
        prefixes: OtelSpanBridge.default_prefixes() ++ [[:normandy, :llm, :request]]
      )

      counter = :counters.new(1, [])

      Req.Test.stub(__MODULE__.RetriedRequest, fn conn ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if n == 0 do
          conn
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{
            "type" => "error",
            "error" => %{"type" => "rate_limit_error", "message" => "slow down"}
          })
        else
          Req.Test.json(conn, %{
            "id" => "msg_1",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-opus-5-5",
            "content" => [%{"type" => "text", "text" => ~s({"chat_message":"hi"})}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          })
        end
      end)

      agent =
        BaseAgent.init(%{
          client: %Normandy.LLM.ClaudioAdapter{
            api_key: "k",
            options: %{req_options: [plug: {Req.Test, __MODULE__.RetriedRequest}, retry: false]}
          },
          model: "claude-opus-5-5",
          temperature: nil,
          retry: [max_attempts: 2, base_delay: 1, jitter: false]
        })

      BaseAgent.run!(agent, "hello")

      spans =
        OtelSpanBridge.await_spans([
          "normandy.agent.run",
          "normandy.agent.llm_call",
          "normandy.llm.request",
          "normandy.llm.request"
        ])

      llm_call = OtelSpanBridge.fetch_span!(spans, "normandy.agent.llm_call")
      requests = Enum.filter(spans, &(&1.name == "normandy.llm.request"))

      assert [_, _] = requests
      assert Enum.all?(requests, &(&1.parent_span_id == llm_call.span_id))
      assert Enum.all?(requests, &(&1.trace_id == llm_call.trace_id))
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
        toolset: Toolset.new([%FakeTool{}])
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

  # A Turn.Server whose config carries `hooks`, with the bridge also opening hook spans.
  defp start_hooked_turn_server(client, hooks, store \\ {InMemory, InMemory.new()}) do
    OtelSpanBridge.attach(prefixes: OtelSpanBridge.default_prefixes() ++ [[:normandy, :hook]])

    config =
      BaseAgent.init(%{
        client: client,
        model: "test-model",
        behaviours: %Normandy.Behaviours.Config{hooks: hooks}
      })

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "span-hook-#{System.unique_integer([:positive])}",
        config: config,
        store: store,
        registry: {Native, Native.new()}
      )

    srv
  end

  describe "Turn.Server hooks outside the run (TEL-3)" do
    test "an on_prompt hook span is a child of the caller, a sibling of run" do
      srv =
        start_hooked_turn_server(counted_client(false), [{Normandy.Test.Hooks.PromptOnly, []}])

      caller = start_caller_span()

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})

      :otel_span.end_span(caller)
      spans = OtelSpanBridge.await_spans(["caller", "normandy.hook", "normandy.agent.run"])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      hook = OtelSpanBridge.fetch_span!(spans, "normandy.hook")
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")

      assert hook.parent_span_id == caller_span.span_id
      assert run.parent_span_id == caller_span.span_id
      assert spans |> Enum.map(& &1.trace_id) |> Enum.uniq() == [caller_span.trace_id]
    end

    test "an on_turn_end hook span is a child of the caller" do
      srv =
        start_hooked_turn_server(counted_client(false), [{Normandy.Test.Hooks.TurnEndOnly, []}])

      caller = start_caller_span()

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})

      :otel_span.end_span(caller)
      # on_turn_end runs after the reply; await_spans blocks until its span ends.
      spans = OtelSpanBridge.await_spans(["caller", "normandy.agent.run", "normandy.hook"])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      hook = OtelSpanBridge.fetch_span!(spans, "normandy.hook")

      assert hook.parent_span_id == caller_span.span_id
      assert hook.trace_id == caller_span.trace_id
    end

    test "a rejected input's on_prompt and on_turn_end hook spans are children of the caller" do
      srv =
        start_hooked_turn_server(counted_client(false), [
          {Normandy.Test.Hooks.PromptOnly, returns: {:halt, "no"}},
          {Normandy.Test.Hooks.TurnEndOnly, []}
        ])

      caller = start_caller_span()

      assert {:error, %Normandy.HookHaltError{}} = Turn.Server.run(srv, %{chat_message: "hi"})

      :otel_span.end_span(caller)

      spans =
        OtelSpanBridge.await_spans([
          "caller",
          "normandy.hook",
          "normandy.hook",
          "normandy.agent.run"
        ])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      hooks = Enum.filter(spans, &(&1.name == "normandy.hook"))
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")

      assert [_, _] = hooks
      assert Enum.all?(hooks, &(&1.parent_span_id == caller_span.span_id))
      assert run.parent_span_id == caller_span.span_id
    end

    test "after a hooked turn the server holds no caller context" do
      srv =
        start_hooked_turn_server(counted_client(false), [{Normandy.Test.Hooks.TurnEndOnly, []}])

      caller = start_caller_span()
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})
      :otel_span.end_span(caller)
      _ = OtelSpanBridge.await_spans(["caller", "normandy.agent.run", "normandy.hook"])

      # The two-element request carries no context: its spans are roots.
      assert {:ok, _} = :gen_statem.call(srv, {:turn, %{chat_message: "again"}}, :infinity)

      spans = OtelSpanBridge.await_spans(["normandy.agent.run", "normandy.hook"])
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")
      hook = OtelSpanBridge.fetch_span!(spans, "normandy.hook")

      assert run.parent_span_id == :undefined
      assert hook.parent_span_id == :undefined
    end

    # X9: Task 6.2's exits (:loading, :unavailable, a load crash, passivation) attach no
    # turn context; a request that arrives in :unavailable is postponed and replayed in
    # :idle, where the :turn clause attaches and releases it like any other.
    @tag :capture_log
    test "a turn replayed after an :unavailable load runs in the caller's context and releases it" do
      store = FlakyStore.new()
      FlakyStore.down(store)

      srv =
        start_hooked_turn_server(
          counted_client(false),
          [{Normandy.Test.Hooks.TurnEndOnly, []}],
          {FlakyStore, store}
        )

      assert {:unavailable, _} = :sys.get_state(srv)
      FlakyStore.up(store)

      # run/2 in :unavailable retries the load and replays the request in :idle.
      caller = start_caller_span()
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})
      :otel_span.end_span(caller)
      spans = OtelSpanBridge.await_spans(["caller", "normandy.agent.run", "normandy.hook"])
      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")

      assert OtelSpanBridge.fetch_span!(spans, "normandy.hook").parent_span_id ==
               caller_span.span_id

      assert {:ok, _} = :gen_statem.call(srv, {:turn, %{chat_message: "again"}}, :infinity)

      spans = OtelSpanBridge.await_spans(["normandy.agent.run", "normandy.hook"])
      assert OtelSpanBridge.fetch_span!(spans, "normandy.agent.run").parent_span_id == :undefined
      assert OtelSpanBridge.fetch_span!(spans, "normandy.hook").parent_span_id == :undefined
    end
  end

  # A server whose "weather" tool needs approval, so the turn parks after the
  # first LLM call. Returns its start options so a test can restart it on the
  # same store.
  defp approval_server_opts(client) do
    test_pid = self()

    config =
      BaseAgent.init(%{
        client: client,
        model: "test-model",
        toolset: Toolset.new([%FakeTool{}])
      })

    policy = %Normandy.Behaviours.Config{
      policy:
        {Normandy.Behaviours.PolicyEngine.Ruleset,
         rules: [%{match: "weather", action: :require_approval, rule_id: "R1"}],
         default_action: :allow}
    }

    [
      session_id: "span-#{System.unique_integer([:positive])}",
      config: %{config | behaviours: policy},
      store: {InMemory, InMemory.new()},
      registry: {Native, Native.new()},
      approval_timeout_ms: 5_000,
      subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
    ]
  end

  # Runs a turn from a fresh process with `ctx` current; replies {:run_result, _}.
  defp run_async_with_ctx(srv, input, ctx) do
    parent = self()

    spawn(fn ->
      OpenTelemetry.Ctx.attach(ctx)
      send(parent, {:run_result, Turn.Server.run(srv, input)})
    end)
  end

  @doc false
  def forward_event(event, measurements, metadata, pid) do
    current = :otel_tracer.current_span_ctx(:otel_ctx.get_current())
    send(pid, {:telemetry, event, measurements, metadata, current})
  end

  defp attach_forward(events) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, events, &__MODULE__.forward_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "Turn.Server durable resume" do
    test "a resumed parked turn emits run :start (resumed: true) under the original trace" do
      Process.flag(:trap_exit, true)
      opts = approval_server_opts(counted_client(true))
      {:ok, first} = Turn.Server.start_link(opts)

      caller = start_caller_span()
      run_async_with_ctx(first, %{chat_message: "hi"}, :otel_ctx.get_current())
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000

      # The restarted server and the approver know nothing of the caller's context.
      OpenTelemetry.Ctx.attach(:otel_ctx.new())
      :ok = :gen_statem.stop(first, :shutdown, 5_000)
      :otel_span.end_span(caller)

      before = OtelSpanBridge.await_spans(["caller", "normandy.agent.run"])
      caller_span = OtelSpanBridge.fetch_span!(before, "caller")
      first_run = OtelSpanBridge.fetch_span!(before, "normandy.agent.run")

      attach_forward([
        [:normandy, :agent, :run, :start],
        [:normandy, :turn, :approval, :start]
      ])

      {:ok, second} = Turn.Server.start_link(Keyword.put(opts, :resume_policy, :eager))
      assert_receive {:event, :awaiting_approval, %{parked: 1, resumed: true}}, 2_000

      sid = opts[:session_id]

      # The server emits run :start before notifying the subscriber, so it is already here.
      assert_received {:telemetry, [:normandy, :agent, :run, :start], _,
                       %{session_id: ^sid, resumed: true}, _}

      # A durable resume into :awaiting_approval opens a fresh approval span. The server
      # emits approval :start only after the :awaiting_approval subscriber event, so wait.
      assert_receive {:telemetry, [:normandy, :turn, :approval, :start], _,
                      %{session_id: ^sid, count: 1}, _},
                     2_000

      :ok = Turn.Server.approve(second, %{"call_1" => :approve})

      spans =
        OtelSpanBridge.await_spans([
          "normandy.agent.run",
          "normandy.tool.execute",
          "normandy.agent.llm_call"
        ])

      resumed_run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")
      tool = OtelSpanBridge.fetch_span!(spans, "normandy.tool.execute")
      llm_call = OtelSpanBridge.fetch_span!(spans, "normandy.agent.llm_call")

      assert first_run.parent_span_id == caller_span.span_id
      assert resumed_run.trace_id == caller_span.trace_id
      assert resumed_run.parent_span_id == caller_span.span_id
      refute resumed_run.span_id == first_run.span_id
      assert tool.parent_span_id == resumed_run.span_id
      assert llm_call.parent_span_id == resumed_run.span_id
    end
  end

  describe "Turn.Server.approve/2" do
    test "the approval :stop sees the approver's context; the run is not reparented" do
      attach_forward([[:normandy, :turn, :approval, :stop]])
      {:ok, srv} = Turn.Server.start_link(approval_server_opts(counted_client(true)))

      caller = start_caller_span()
      run_async_with_ctx(srv, %{chat_message: "hi"}, :otel_ctx.get_current())
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000

      tracer = :opentelemetry.get_application_tracer(__MODULE__)
      approver = :otel_tracer.start_span(:otel_ctx.new(), tracer, "approver", %{})
      OpenTelemetry.Ctx.attach(:otel_tracer.set_current_span(:otel_ctx.new(), approver))

      :ok = Turn.Server.approve(srv, %{"call_1" => :approve})
      assert_receive {:run_result, {:ok, _}}, 5_000

      :otel_span.end_span(approver)
      :otel_span.end_span(caller)

      assert_received {:telemetry, [:normandy, :turn, :approval, :stop], _, _, seen}
      assert :otel_span.trace_id(seen) == :otel_span.trace_id(approver)

      assert_run_children_under_run()
    end

    # With the approval span itself bridged, the bridge restores the run's context on
    # :stop; the server must not then put the approval span's context back.
    test "a bridged approval span does not leak into the work after approval" do
      OtelSpanBridge.attach(
        prefixes: OtelSpanBridge.default_prefixes() ++ [[:normandy, :turn, :approval]]
      )

      {:ok, srv} = Turn.Server.start_link(approval_server_opts(counted_client(true)))

      caller = start_caller_span()
      run_async_with_ctx(srv, %{chat_message: "hi"}, :otel_ctx.get_current())
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000

      tracer = :opentelemetry.get_application_tracer(__MODULE__)
      approver = :otel_tracer.start_span(:otel_ctx.new(), tracer, "approver", %{})
      OpenTelemetry.Ctx.attach(:otel_tracer.set_current_span(:otel_ctx.new(), approver))

      :ok = Turn.Server.approve(srv, %{"call_1" => :approve})
      assert_receive {:run_result, {:ok, _}}, 5_000

      :otel_span.end_span(approver)
      :otel_span.end_span(caller)

      spans = assert_run_children_under_run()
      approval = OtelSpanBridge.fetch_span!(spans, "normandy.turn.approval")
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")
      assert approval.parent_span_id == run.span_id
    end
  end

  # The tool and the post-approval llm_call nest under the run, in the caller's trace.
  defp assert_run_children_under_run do
    spans =
      OtelSpanBridge.await_spans([
        "caller",
        "approver",
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
    assert Enum.all?(llm_calls, &(&1.trace_id == caller_span.trace_id))
    spans
  end

  # Replies with text: a chained step feeds the reply to the next agent, and the
  # default input schema rejects a nil chat_message.
  defp text_agent do
    BaseAgent.init(%{
      client: %StubClient{reply: fn model -> Map.put(model, :chat_message, "ok") end},
      model: "test-model"
    })
  end

  defp final_agent do
    BaseAgent.init(%{client: counted_client(false), model: "test-model"})
  end

  # Asserts every run span is a direct child of the caller span, in its trace.
  defp assert_runs_under_caller(caller, run_count) do
    :otel_span.end_span(caller)

    spans =
      OtelSpanBridge.await_spans(["caller" | List.duplicate("normandy.agent.run", run_count)])

    caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
    runs = Enum.filter(spans, &(&1.name == "normandy.agent.run"))

    assert length(runs) == run_count
    assert Enum.all?(runs, &(&1.parent_span_id == caller_span.span_id))
    assert spans |> Enum.map(& &1.trace_id) |> Enum.uniq() == [caller_span.trace_id]
  end

  defmodule WfAgent do
    use Normandy.DSL.Agent

    agent do
      model("test-model")
      system_prompt("wf")
    end
  end

  describe "workflow" do
    defmodule OneStepWorkflow do
      use Normandy.DSL.Workflow

      workflow do
        step :only do
          agent(NormandyTest.Telemetry.SpanHierarchyTest.WfAgent)
          input("hi")
        end
      end
    end

    test "workflow.run nests the step's agent run under it, under the caller" do
      OtelSpanBridge.attach(
        prefixes: OtelSpanBridge.default_prefixes() ++ [[:normandy, :workflow, :run]]
      )

      caller = start_caller_span()

      assert {:ok, _} =
               OneStepWorkflow.execute(
                 agents: %{__MODULE__.WfAgent => final_agent()},
                 initial_input: "hi"
               )

      :otel_span.end_span(caller)

      spans =
        OtelSpanBridge.await_spans([
          "caller",
          "normandy.workflow.run",
          "normandy.agent.run"
        ])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      workflow = OtelSpanBridge.fetch_span!(spans, "normandy.workflow.run")
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")

      assert workflow.parent_span_id == caller_span.span_id
      assert run.parent_span_id == workflow.span_id
      assert run.trace_id == caller_span.trace_id
    end
  end

  describe "orchestrators" do
    test "SequentialOrchestrator.execute nests each agent run under its workflow span" do
      OtelSpanBridge.attach(
        prefixes: OtelSpanBridge.default_prefixes() ++ [[:normandy, :workflow, :run]]
      )

      caller = start_caller_span()
      specs = [%{id: "a", agent: text_agent()}, %{id: "b", agent: text_agent()}]
      assert {:ok, _} = SequentialOrchestrator.execute(specs, "hi", [])
      :otel_span.end_span(caller)

      spans =
        OtelSpanBridge.await_spans([
          "caller",
          "normandy.workflow.run",
          "normandy.agent.run",
          "normandy.agent.run"
        ])

      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")
      workflow = OtelSpanBridge.fetch_span!(spans, "normandy.workflow.run")
      runs = Enum.filter(spans, &(&1.name == "normandy.agent.run"))

      assert workflow.parent_span_id == caller_span.span_id
      assert Enum.all?(runs, &(&1.parent_span_id == workflow.span_id))
    end

    test "ParallelOrchestrator.execute nests each spawned run under its workflow span" do
      OtelSpanBridge.attach(
        prefixes: OtelSpanBridge.default_prefixes() ++ [[:normandy, :workflow, :run]]
      )

      caller = start_caller_span()

      specs = [
        %{id: "a", agent: final_agent(), input: %{chat_message: "hi"}},
        %{id: "b", agent: final_agent(), input: %{chat_message: "hi"}}
      ]

      assert {:ok, _} = ParallelOrchestrator.execute(specs, nil)
      :otel_span.end_span(caller)

      spans =
        OtelSpanBridge.await_spans([
          "caller",
          "normandy.workflow.run",
          "normandy.agent.run",
          "normandy.agent.run"
        ])

      workflow = OtelSpanBridge.fetch_span!(spans, "normandy.workflow.run")
      runs = Enum.filter(spans, &(&1.name == "normandy.agent.run"))

      assert Enum.all?(runs, &(&1.parent_span_id == workflow.span_id))
    end
  end

  describe "coordination fan-out" do
    test "Reactive.all nests each agent run under the caller" do
      caller = start_caller_span()

      assert {:ok, _} = Reactive.all([final_agent(), final_agent()], %{chat_message: "hi"})

      assert_runs_under_caller(caller, 2)
    end

    test "Reactive.race nests the agent runs under the caller" do
      caller = start_caller_span()

      assert {:ok, _} = Reactive.race([final_agent(), final_agent()], %{chat_message: "hi"})

      # The loser may be killed before its run span ends; the winner always ends.
      :otel_span.end_span(caller)
      spans = OtelSpanBridge.await_spans(["caller", "normandy.agent.run"])
      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")

      assert spans |> Enum.map(& &1.trace_id) |> Enum.uniq() == [caller_span.trace_id]
    end

    # Documents a limitation: the coordinator's synthetic killed exception fires
    # outside the killed process, so a process-keyed bridge can't end its span.
    test "Reactive.race: a killed loser's run span is never exported" do
      stuck =
        BaseAgent.init(%{
          client: %StubClient{reply: fn _ -> receive do: (:never -> :ok) end},
          model: "test-model"
        })

      caller = start_caller_span()

      assert {:ok, _} = Reactive.race([final_agent(), stuck], %{chat_message: "hi"})

      :otel_span.end_span(caller)
      spans = OtelSpanBridge.await_spans(["caller", "normandy.agent.run"])

      assert [_winner] = Enum.filter(spans, &(&1.name == "normandy.agent.run"))
      refute_receive {:span, _}, 50
    end

    test "Reactive.some nests the agent runs under the caller" do
      caller = start_caller_span()

      assert {:ok, _} =
               Reactive.some([final_agent(), final_agent()], %{chat_message: "hi"}, count: 1)

      :otel_span.end_span(caller)
      spans = OtelSpanBridge.await_spans(["caller", "normandy.agent.run"])
      caller_span = OtelSpanBridge.fetch_span!(spans, "caller")

      assert spans |> Enum.map(& &1.trace_id) |> Enum.uniq() == [caller_span.trace_id]
    end

    test "ParallelOrchestrator.execute nests each spec run under the caller" do
      caller = start_caller_span()

      specs = [
        %{id: "a", agent: final_agent(), input: %{chat_message: "hi"}},
        %{id: "b", agent: final_agent(), input: %{chat_message: "hi"}}
      ]

      assert {:ok, _} = ParallelOrchestrator.execute(specs, nil)

      assert_runs_under_caller(caller, 2)
    end

    test "ParallelOrchestrator.execute_stream nests each spec run under the caller" do
      caller = start_caller_span()

      specs = [%{id: "a", agent: final_agent(), input: %{chat_message: "hi"}}]

      assert [{:ok, {:ok, {"a", _}}}] =
               ParallelOrchestrator.execute_stream(specs) |> Enum.to_list()

      assert_runs_under_caller(caller, 1)
    end

    test "Batch.Processor.process_batch nests each item run under the caller" do
      caller = start_caller_span()

      assert {:ok, _} =
               Processor.process_batch(final_agent(), [
                 %{chat_message: "one"},
                 %{chat_message: "two"}
               ])

      assert_runs_under_caller(caller, 2)
    end

    test "AgentProcess.run (inline) nests the run under the caller" do
      {:ok, pid} = AgentProcess.start_link(agent: final_agent())
      caller = start_caller_span()

      assert {:ok, _} = AgentProcess.run(pid, %{chat_message: "hi"})

      assert_runs_under_caller(caller, 1)
    end

    test "AgentProcess.run (inline) does not leak the caller context into the next call" do
      {:ok, pid} = AgentProcess.start_link(agent: final_agent())
      caller = start_caller_span()

      assert {:ok, _} = AgentProcess.run(pid, %{chat_message: "hi"})
      assert_runs_under_caller(caller, 1)

      # The old message shape carries no context: its run must be a root span.
      assert {:ok, _} = GenServer.call(pid, {:run, %{chat_message: "again"}})
      spans = OtelSpanBridge.await_spans(["normandy.agent.run"])
      run = OtelSpanBridge.fetch_span!(spans, "normandy.agent.run")

      assert run.parent_span_id == :undefined
    end

    test "AgentProcess.run (server engine) nests the run under the caller" do
      {:ok, pid} = AgentProcess.start_link(agent: final_agent(), turn_engine: :server)
      caller = start_caller_span()

      assert {:ok, _} = AgentProcess.run(pid, %{chat_message: "hi"})

      assert_runs_under_caller(caller, 1)
    end

    test "AgentProcess.cast nests the run under the caller" do
      {:ok, pid} = AgentProcess.start_link(agent: final_agent())
      caller = start_caller_span()

      :ok = AgentProcess.cast(pid, %{chat_message: "hi"}, reply_to: self())
      assert_receive {:agent_result, _, {:ok, _}}, 5_000

      assert_runs_under_caller(caller, 1)
    end
  end
end
