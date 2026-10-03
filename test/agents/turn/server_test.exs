defmodule Normandy.Agents.Turn.ServerTest do
  use ExUnit.Case, async: true
  import Normandy.Test.Eventually

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Horde
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Test.FakeTool

  # A response model the FSM finalizes on: no tool_calls → :completed.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def __str__(resp), do: resp.content
    def __rich__(resp), do: resp.content
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # Input schema with a required field: `%{}` fails validation (ValidationError).
  defmodule RequiredQueryInput do
    use Normandy.Schema

    io_schema "Input requiring a query" do
      field(:query, :string, description: "query", required: true)
    end
  end

  # A store that fails the assistant-message append (delegating everything else to
  # InMemory). Used to drive the server's `fail/2` bypass with a NON-terminal turn
  # state (the :tool_dispatch `{:append_message, "assistant", _}`), proving the
  # terminal state persisted on failure is :failed.
  defmodule AssistantAppendFailStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory
    def new, do: InMemory.new()
    def append_entry(_h, _sid, %{role: "assistant"}), do: {:error, :boom}
    def append_entry(h, sid, e), do: InMemory.append_entry(h, sid, e)
    def save_turn_state(h, sid, t), do: InMemory.save_turn_state(h, sid, t)
    def load_turn_state(h, sid), do: InMemory.load_turn_state(h, sid)
    def history(h, sid), do: InMemory.history(h, sid)
  end

  # InMemory wrapper whose Nth append (counted from the first append through this
  # wrapper) fails once, then behaves normally. Handle: {inmem, counter_agent, n}.
  defmodule FlakyAppendStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory

    def new(fail_at) do
      inmem = InMemory.new()
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      {inmem, counter, fail_at}
    end

    def append_entry({inmem, counter, fail_at}, sid, entry) do
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if n == fail_at,
        do: {:error, :disk_full},
        else: InMemory.append_entry(inmem, sid, entry)
    end

    def save_turn_state({h, _, _}, sid, t), do: InMemory.save_turn_state(h, sid, t)
    def load_turn_state({h, _, _}, sid), do: InMemory.load_turn_state(h, sid)
    def history({h, _, _}, sid), do: InMemory.history(h, sid)
  end

  # Minimal config the reused BaseAgent helpers tolerate for a no-tools turn.
  # `client` is a fake the call_llm helper will hit; for the unit test we inject
  # the LLM via a stub handler set rather than a real client (see Step 3 note).
  defp base_config do
    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: AgentMemory.new_memory(),
      tool_registry: nil
    }
  end

  # Config with weather + billing tools registered.
  defp base_config_with_tools do
    tools = [
      %FakeTool{name: "weather"},
      %FakeTool{name: "billing"}
    ]

    %{base_config() | tool_registry: Normandy.Tools.Registry.new(tools)}
  end

  # Config with notify-instrumented tools so tests can assert whether billing ran.
  # `pid` is the test pid that receives `{:tool_ran, "billing"}` if the tool executes.
  defp config_with_notify(pid) do
    tools = [
      %FakeTool{name: "weather", notify: pid},
      %FakeTool{name: "billing", notify: pid}
    ]

    %{base_config() | tool_registry: Normandy.Tools.Registry.new(tools)}
  end

  test "a no-tools turn runs to :finalize and replies the final response" do
    store = InMemory.new()
    reg = Native.new()

    # Inject a fake LLM via the :handlers override (test seam, see Step 3).
    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req -> %Resp{content: "hi", tool_calls: nil} end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s1",
        config: base_config(),
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers,
        subscriber: nil
      )

    assert {:ok, final} = Turn.Server.run(srv, "hello")
    assert %Resp{content: "hi"} = final
  end

  test "a turn compacts memory before its first LLM call" do
    test_pid = self()

    handlers = %{
      BaseAgent.non_streaming_handlers()
      | compact: fn config, _state, _info ->
          send(test_pid, :compacted)
          {config, %{compacted: false}}
        end,
        call_llm: fn _config, _state, _req ->
          send(test_pid, :llm_called)
          %Resp{content: "hi", tool_calls: nil}
        end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-compact-first",
        config: base_config(),
        store: {InMemory, InMemory.new()},
        registry: {Normandy.Behaviours.SessionRegistry.Native, Native.new()},
        handlers: handlers
      )

    assert {:ok, _} = Turn.Server.run(srv, "hello")
    assert {:messages, [:compacted, :llm_called]} = Process.info(self(), :messages)
  end

  test "the store holds the admitted user input, the same value memory holds" do
    store = InMemory.new()

    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req -> %Resp{content: "noted", tool_calls: nil} end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-admitted",
        config: %{base_config() | input_schema: %Normandy.Agents.BaseAgentInputSchema{}},
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, Native.new()},
        handlers: handlers
      )

    assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "My locker number is 4417."})

    {:ok, [user | _]} = InMemory.history(store, "s-admitted")

    assert %Normandy.Agents.BaseAgentInputSchema{chat_message: "My locker number is 4417."} =
             user.content
  end

  test "a completed turn persists a terminal :stopped turn state (for the resume reaper)" do
    store = InMemory.new()
    reg = Native.new()

    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req -> %Resp{content: "done", tool_calls: nil} end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-fin",
        config: base_config(),
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers
      )

    assert {:ok, _} = Turn.Server.run(srv, "hello")
    assert {:ok, %Turn.State{status: :stopped}} = InMemory.load_turn_state(store, "s-fin")
  end

  test "a failed turn persists a terminal :failed turn state (for the resume reaper)" do
    store = InMemory.new()
    reg = Native.new()

    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req -> raise "boom" end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-fail",
        config: base_config(),
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers
      )

    # The spawned LLM task crashes by design; capture the expected error report
    # so test output stays pristine.
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _} = Turn.Server.run(srv, "hello")
    end)

    assert {:ok, %Turn.State{status: :failed}} = InMemory.load_turn_state(store, "s-fail")
  end

  test "fail/2 bypass (mid-turn append failure) persists a terminal :failed turn state" do
    # A tool turn enters :tool_dispatch and emits {:append_message, "assistant", resp};
    # failing that append invokes the server's fail/2 helper with a NON-terminal
    # turn_state (:tool_dispatch). The terminal state persisted for the reaper must
    # still be :failed (not :tool_dispatch).
    store = AssistantAppendFailStore.new()
    reg = Native.new()

    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r ->
          %Resp{content: "", tool_calls: [%ToolCall{id: "c1", name: "weather", input: %{}}]}
        end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-bypass",
        config: base_config_with_tools(),
        store: {AssistantAppendFailStore, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers
      )

    assert {:error, {:persist_failed, _}} = Turn.Server.run(srv, "do stuff")

    assert {:ok, %Turn.State{status: :failed}} =
             AssistantAppendFailStore.load_turn_state(store, "s-bypass")
  end

  test "an output guardrail block replies {:rejected, e} and keeps the answer out of memory and store" do
    store = InMemory.new()
    reg = Native.new()

    config = %{
      base_config()
      | output_guardrails: [
          {Normandy.Guardrails.Builtins.ForbiddenSubstrings, terms: ["SSN"], field: :content}
        ]
    }

    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r -> %Resp{content: "your SSN is 123", tool_calls: nil} end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-output-block",
        config: config,
        store: {InMemory, store},
        registry: {Native, reg},
        handlers: handlers
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:rejected, %Normandy.Guardrails.ViolationError{}}} =
                 Turn.Server.run(srv, "what is my ssn?")
      end)

    refute log =~ "handler"
    {:ok, entries} = InMemory.history(store, "s-output-block")
    refute Enum.any?(entries, &(&1.role == "assistant"))

    {_state, data} = :sys.get_state(srv)
    refute Enum.any?(AgentMemory.messages(data.config.memory), &(&1.role == "assistant"))
  end

  defmodule TemplateFaultStore do
    def load_config_template(_handle, _sid), do: {:error, :store_unavailable}
  end

  test "a thin start whose template load faults replies the store's reason to run/2" do
    {:ok, cat} = Catalog.start_link([])

    assert {:ok, srv} =
             Turn.Server.start_link(
               session_id: "s-template-fault",
               store: {TemplateFaultStore, nil},
               registry: {Native, Native.new()},
               template_provider: {Catalog, cat}
             )

    assert {:error, :store_unavailable} = Turn.Server.run(srv, "hello")
  end

  test "a Tier-2 thin start without :config or :template_provider fails fast (clear error)" do
    store = InMemory.new()
    reg = Native.new()

    opts = [
      session_id: "s-misconfig",
      store: {InMemory, store},
      registry: {Normandy.Behaviours.SessionRegistry.Native, reg}
      # deliberately neither :config nor :template_provider
    ]

    # init raises an ArgumentError → start_link returns {:error, _}; capture the
    # expected crash report so output stays pristine.
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _reason} = Turn.Server.start_link(opts)
    end)
  end

  test "a batch with a needs_approval call parks the turn (:awaiting_approval) and persists" do
    store = InMemory.new()
    reg = Native.new()
    test_pid = self()

    # First LLM response asks for two tool calls; classify parks one of them.
    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r ->
          %Resp{
            content: "",
            tool_calls: [
              %ToolCall{id: "ok1", name: "weather", input: %{}},
              %ToolCall{id: "pk1", name: "billing", input: %{}}
            ]
          }
        end
    }

    # Policy: billing → needs_approval, everything else allow.
    config = %{
      base_config_with_tools()
      | behaviours: %Normandy.Behaviours.Config{
          policy:
            {Normandy.Behaviours.PolicyEngine.Ruleset,
             rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
             default_action: :allow}
        }
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-park",
        config: config,
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers,
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      )

    # run/2 will block (no reply until resume); kick it from a spawned process.
    spawn(fn -> Turn.Server.run(srv, "do stuff") end)

    assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
    assert {:ok, _term} = InMemory.load_turn_state(store, "s-park")
  end

  test "tool results keep the order of the tool calls when one is denied" do
    store = InMemory.new()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn _c, _s, _r ->
      if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0 do
        %Resp{
          content: "",
          tool_calls: [
            %ToolCall{id: "denied1", name: "billing", input: %{}},
            %ToolCall{id: "ran1", name: "weather", input: %{}}
          ]
        }
      else
        %Resp{content: "done", tool_calls: nil}
      end
    end

    config = %{
      base_config_with_tools()
      | behaviours: %Normandy.Behaviours.Config{
          policy:
            {Normandy.Behaviours.PolicyEngine.Ruleset,
             rules: [%{match: "billing", action: :deny, rule_id: "R1"}], default_action: :allow}
        }
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-order",
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
      )

    assert {:ok, _} = Turn.Server.run(srv, "go")

    {:ok, entries} = InMemory.history(store, "s-order")

    ids =
      for %{role: "tool", content: content} <- entries,
          %ToolResult{tool_call_id: id} <- List.wrap(content),
          do: id

    assert ids == ["denied1", "ran1"]
  end

  test "stored entries carry the turn id of the turn that wrote them" do
    store = InMemory.new()

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-turn-ids",
        config: base_config(),
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: %{
          BaseAgent.non_streaming_handlers()
          | call_llm: fn _c, _s, _r -> %Resp{content: "ok", tool_calls: nil} end
        }
      )

    assert {:ok, _} = Turn.Server.run(srv, "one")
    assert {:ok, _} = Turn.Server.run(srv, "two")

    {:ok, entries} = InMemory.history(store, "s-turn-ids")
    assert [t1, t1, t2, t2] = Enum.map(entries, & &1.turn_id)
    assert is_binary(t1) and is_binary(t2) and t1 != t2
    refute t1 == "live"
  end

  test "in-flight work stops when the server dies" do
    parent = self()

    call_llm = fn _c, _s, _r ->
      send(parent, {:llm_running, self()})
      Process.sleep(:infinity)
    end

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-orphan",
        config: base_config(),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
      )

    Process.unlink(srv)
    spawn(fn -> Turn.Server.run(srv, "go") end)
    assert_receive {:llm_running, llm_pid}, 1_000

    ref = Process.monitor(llm_pid)
    Process.exit(srv, :kill)

    assert_receive {:DOWN, ^ref, :process, ^llm_pid, _}, 1_000
  end

  describe "run telemetry" do
    setup do
      parent = self()
      id = "server-run-span-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        id,
        [
          [:normandy, :agent, :run, :start],
          [:normandy, :agent, :run, :stop],
          [:normandy, :agent, :run, :exception]
        ],
        fn event, measurements, meta, _ ->
          if meta[:session_id], do: send(parent, {:run_event, event, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    defp start_span_server(sid, call_llm) do
      {:ok, srv} =
        Turn.Server.start_link(
          session_id: sid,
          config: base_config(),
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()},
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
        )

      srv
    end

    test "a turn emits run :start and :stop with the session id" do
      srv =
        start_span_server("s-span", fn _c, _s, _r -> %Resp{content: "ok", tool_calls: nil} end)

      assert {:ok, _} = Turn.Server.run(srv, "go")

      assert_received {:run_event, [:normandy, :agent, :run, :start], %{system_time: _},
                       %{session_id: "s-span", model: "test"}}

      assert_received {:run_event, [:normandy, :agent, :run, :stop], %{duration: d},
                       %{session_id: "s-span"}}

      assert is_integer(d) and d >= 0
    end

    test "a failed turn emits run :exception with the reason" do
      srv = start_span_server("s-span-fail", fn _c, _s, _r -> raise "llm down" end)

      ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = Turn.Server.run(srv, "go") end)

      assert_received {:run_event, [:normandy, :agent, :run, :start], _,
                       %{session_id: "s-span-fail"}}

      assert_received {:run_event, [:normandy, :agent, :run, :exception], %{duration: _},
                       %{session_id: "s-span-fail", kind: :error, reason: {:task_down, _}}}
    end
  end

  describe "stray messages and termination" do
    @describetag :capture_log

    setup do
      parent = self()
      id = "server-stray-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        id,
        [[:normandy, :agent, :run, :start], [:normandy, :agent, :run, :exception]],
        fn event, measurements, meta, _ ->
          if meta[:session_id], do: send(parent, {:run_event, event, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    defp stray_messages do
      [
        :stray,
        {make_ref(), :late_result},
        {:DOWN, make_ref(), :process, self(), :boom},
        {:EXIT, spawn(fn -> :ok end), :boom}
      ]
    end

    defp flood_with_strays(srv) do
      Enum.each(stray_messages(), &send(srv, &1))
      # A synchronous call after the sends proves the server processed them and lives.
      :sys.get_state(srv)
      assert Process.alive?(srv)
    end

    defp final_llm, do: fn _c, _s, _r -> %Resp{content: "ok", tool_calls: nil} end

    defp blocking_llm(test_pid) do
      fn _c, _s, _r ->
        send(test_pid, {:llm_started, self()})

        receive do
          :release -> %Resp{content: "ok", tool_calls: nil}
        end
      end
    end

    test "stray messages in :idle do not crash the server" do
      {srv, _store} =
        start_server("s-stray-idle", base_config(),
          handlers: final_handlers(%{call_llm: final_llm()})
        )

      flood_with_strays(srv)
      assert {:ok, %Resp{content: "ok"}} = Turn.Server.run(srv, "go")
    end

    test "stray messages in :running do not crash the server or the turn" do
      {srv, _store} =
        start_server("s-stray-running", base_config(),
          handlers: final_handlers(%{call_llm: blocking_llm(self())})
        )

      caller = run_async(srv, "go")
      assert_receive {:llm_started, worker}, 1_000
      assert {:running, _} = {elem(:sys.get_state(srv), 0), caller}

      flood_with_strays(srv)
      send(worker, :release)

      assert_receive {:run_result, {:ok, %Resp{content: "ok"}}}, 2_000

      run_async(srv, "again")
      assert_receive {:llm_started, worker2}, 1_000
      send(worker2, :release)
      assert_receive {:run_result, {:ok, %Resp{content: "ok"}}}, 2_000
    end

    test "stray messages in :awaiting_approval do not crash the server" do
      {srv, _store} = start_approval_server("s-stray-approval", approval_timeout_ms: 60_000)

      run_async(srv, "go")
      assert_receive {:event, :awaiting_approval, _}, 2_000
      assert {:awaiting_approval, _} = {elem(:sys.get_state(srv), 0), :ok}

      flood_with_strays(srv)
      Turn.Server.approve(srv, %{"pk1" => :approve})

      assert_receive {:run_result, {:ok, %Resp{content: "done"}}}, 2_000
    end

    test "stopping a server mid-turn emits run :exception with kind :exit" do
      Process.flag(:trap_exit, true)

      {srv, _store} =
        start_server("s-stop-mid", base_config(),
          handlers: final_handlers(%{call_llm: blocking_llm(self())})
        )

      run_async(srv, "go")
      assert_receive {:llm_started, _worker}, 1_000

      assert_receive {:run_event, [:normandy, :agent, :run, :start], _,
                      %{session_id: "s-stop-mid"}}

      :ok = :gen_statem.stop(srv, :shutdown, 5_000)

      assert_receive {:run_event, [:normandy, :agent, :run, :exception], %{duration: d},
                      %{
                        session_id: "s-stop-mid",
                        kind: :exit,
                        reason: :shutdown,
                        stacktrace: [],
                        model: "test"
                      }},
                     1_000

      assert is_integer(d) and d >= 0
    end

    test "stopping an idle server emits no run :exception" do
      Process.flag(:trap_exit, true)
      {srv, _store} = start_server("s-stop-idle", base_config())
      assert {:ok, _} = Turn.Server.run(srv, "go")
      :ok = :gen_statem.stop(srv, :shutdown, 5_000)

      refute_receive {:run_event, [:normandy, :agent, :run, :exception], _,
                      %{session_id: "s-stop-idle"}},
                     100
    end
  end

  test "approving a parked call resumes the turn and finalizes" do
    store = InMemory.new()
    reg = Native.new()
    test_pid = self()
    parent = self()

    # Stateful call_llm: 1st call → two tool calls (weather allowed, billing parked);
    # 2nd call → no-tools final response.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn _c, _s, _r ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      if n == 0 do
        %Resp{
          content: "",
          tool_calls: [
            %ToolCall{id: "ok1", name: "weather", input: %{}},
            %ToolCall{id: "pk1", name: "billing", input: %{}}
          ]
        }
      else
        %Resp{content: "done", tool_calls: nil}
      end
    end

    handlers = %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}

    # Use notify-instrumented tools so we can assert billing DID execute after approval.
    config = %{
      config_with_notify(test_pid)
      | behaviours: %Normandy.Behaviours.Config{
          policy:
            {Normandy.Behaviours.PolicyEngine.Ruleset,
             rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
             default_action: :allow}
        }
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-approve",
        config: config,
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers,
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      )

    spawn(fn -> send(parent, {:run_result, Turn.Server.run(srv, "go")}) end)

    assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000

    :ok = Turn.Server.approve(srv, %{"pk1" => :approve})

    assert_receive {:run_result, {:ok, %Resp{}}}, 2_000
    # Prove billing WAS executed after approval (fail-open guard: not just finalized).
    assert_receive {:tool_ran, "billing"}, 2_000
  end

  test "passivates (stops :normal) after the idle timeout" do
    store = InMemory.new()
    reg = Native.new()

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-idle",
        config: base_config(),
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: %{
          BaseAgent.non_streaming_handlers()
          | call_llm: fn _c, _s, _r -> %Resp{content: "x"} end
        },
        idle_timeout_ms: 50
      )

    ref = Process.monitor(srv)
    {:ok, _} = Turn.Server.run(srv, "hi")
    assert_receive {:DOWN, ^ref, :process, ^srv, :normal}, 1_000
  end

  test "a turn request received while :running is postponed and runs after idle" do
    store = InMemory.new()
    reg = Native.new()
    parent = self()

    # call_llm reports that it started, then holds the server :running until the
    # test releases it, so the second turn request is sure to arrive meanwhile.
    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r ->
          send(parent, {:llm_started, self()})

          receive do
            :release -> %Resp{content: "x"}
          end
        end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-postpone",
        config: base_config(),
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers
      )

    # First turn: arrives while server is :idle → starts immediately.
    spawn(fn -> send(parent, {:a, Turn.Server.run(srv, "first")}) end)
    # Wait for the LLM task to actually start (deterministic: server is now :running).
    assert_receive {:llm_started, first_llm}, 1_000
    # Second turn: arrives while server is :running → postponed, replayed on :idle entry.
    second = spawn(fn -> send(parent, {:b, Turn.Server.run(srv, "second")}) end)
    # Once the caller waits on its reply, its request is in the server's mailbox.
    assert wait_until(fn -> Process.info(second, :status) == {:status, :waiting} end)
    refute_received {:b, _}

    send(first_llm, :release)
    assert_receive {:a, {:ok, %Resp{}}}, 2_000

    # The postponed turn runs only now, after the first one finished.
    assert_receive {:llm_started, second_llm}, 1_000
    send(second_llm, :release)
    assert_receive {:b, {:ok, %Resp{}}}, 2_000
  end

  test "stale/late approval cast in :idle state does not crash the server" do
    store = InMemory.new()
    reg = Native.new()
    parent = self()

    # Stateful call_llm: 1st call (turn "go") → two tool calls; 2nd call → final;
    # 3rd call (turn "again") → final with no tools.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn _c, _s, _r ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      if n == 0 do
        %Resp{
          content: "",
          tool_calls: [
            %ToolCall{id: "ok1", name: "weather", input: %{}},
            %ToolCall{id: "pk1", name: "billing", input: %{}}
          ]
        }
      else
        %Resp{content: "done", tool_calls: nil}
      end
    end

    handlers = %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}

    config = %{
      base_config_with_tools()
      | behaviours: %Normandy.Behaviours.Config{
          policy:
            {Normandy.Behaviours.PolicyEngine.Ruleset,
             rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
             default_action: :allow}
        }
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-stale-approval",
        config: config,
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers,
        subscriber: fn name, meta -> send(parent, {:event, name, meta}) end
      )

    # Start the first turn; it will park awaiting billing approval.
    spawn(fn -> send(parent, {:run_result, Turn.Server.run(srv, "go")}) end)
    assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000

    # Send the real approval so the first turn completes.
    :ok = Turn.Server.approve(srv, %{"pk1" => :approve})
    assert_receive {:run_result, {:ok, %Resp{}}}, 2_000

    # Server is now :idle. Send a stale/duplicate approval — must NOT crash.
    ref = Process.monitor(srv)
    :ok = Turn.Server.approve(srv, %{"pk1" => :approve})
    refute_receive {:DOWN, ^ref, _, _, _}, 200

    # Server still accepts a new turn after the stale cast.
    assert {:ok, _} = Turn.Server.run(srv, "again")
  end

  test "append_entry failure during user message persist returns {:error, {:persist_failed, _}}" do
    # Tiny inline store where append_entry always fails.
    defmodule FailingAppendStore do
      @behaviour Normandy.Behaviours.SessionStore

      def new, do: :handle

      @impl true
      def save_turn_state(_handle, _sid, _state), do: :ok

      @impl true
      def load_turn_state(_handle, _sid), do: :error

      @impl true
      def append_entry(_handle, _sid, _entry), do: {:error, :disk_full}

      @impl true
      def history(_handle, _sid), do: {:ok, []}

      @impl true
      def fork(_handle, _sid, _new_sid), do: {:error, :nope}
    end

    reg = Native.new()

    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r -> %Resp{content: "unreachable", tool_calls: nil} end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-fail-append",
        config: base_config(),
        store: {FailingAppendStore, :handle},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers
      )

    assert {:error, {:persist_failed, :disk_full}} = Turn.Server.run(srv, "hi")
  end

  test "approval timeout rejects all parked calls (fail-closed) and resumes" do
    store = InMemory.new()
    reg = Native.new()
    test_pid = self()
    parent = self()

    # Stateful call_llm: 1st call → two tool calls; 2nd call → no-tools final.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn _c, _s, _r ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      if n == 0 do
        %Resp{
          content: "",
          tool_calls: [
            %ToolCall{id: "ok1", name: "weather", input: %{}},
            %ToolCall{id: "pk1", name: "billing", input: %{}}
          ]
        }
      else
        %Resp{content: "done", tool_calls: nil}
      end
    end

    handlers = %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}

    # Use notify-instrumented tools so we can assert billing was NOT executed on timeout.
    config = %{
      config_with_notify(test_pid)
      | behaviours: %Normandy.Behaviours.Config{
          policy:
            {Normandy.Behaviours.PolicyEngine.Ruleset,
             rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
             default_action: :allow}
        }
    }

    # Short timeout so the approval_expiry fires quickly.
    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-timeout",
        config: config,
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers,
        approval_timeout_ms: 50,
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      )

    spawn(fn -> send(parent, {:run_result, Turn.Server.run(srv, "go")}) end)

    # The turn should finalize (billing denied by timeout, not approved) via the
    # 2nd no-tools LLM call.
    assert_receive {:run_result, {:ok, %Resp{}}}, 2_000
    # Prove billing was NOT executed (fail-closed Global Constraint: timeout → reject).
    refute_receive {:tool_ran, "billing"}, 100
  end

  test "an eagerly resumed parked turn re-announces :awaiting_approval with resumed: true" do
    test_pid = self()
    call = %ToolCall{id: "pk1", name: "billing", input: %{}}

    parked = %Turn.State{
      status: :awaiting_approval,
      iterations_left: 5,
      max_iterations: 5,
      response_model: %Resp{},
      output_schema: %Resp{},
      pending_calls: [call],
      parked_calls: [call],
      held_results: []
    }

    store = InMemory.new()
    :ok = InMemory.save_turn_state(store, "s-resume-announce", parked)

    {:ok, _srv} =
      Turn.Server.start_link(
        session_id: "s-resume-announce",
        config: base_config(),
        store: {InMemory, store},
        registry: {Native, Native.new()},
        resume_policy: :eager,
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      )

    assert_receive {:event, :awaiting_approval, %{parked: 1, resumed: true}}, 1_000
  end

  # A Turn.State persisted before trace_carrier existed decodes without the key.
  test "a resumed turn persisted without a trace carrier emits run :start with resumed: true" do
    test_pid = self()
    sid = "s-resume-legacy"
    call = %ToolCall{id: "pk1", name: "billing", input: %{}}

    parked =
      %Turn.State{
        status: :awaiting_approval,
        iterations_left: 5,
        max_iterations: 5,
        response_model: %Resp{},
        output_schema: %Resp{},
        pending_calls: [call],
        parked_calls: [call],
        held_results: []
      }
      |> Map.delete(:trace_carrier)

    store = InMemory.new()
    :ok = InMemory.save_turn_state(store, sid, parked)

    :telemetry.attach(
      {__MODULE__, sid},
      [:normandy, :agent, :run, :start],
      &__MODULE__.handle_telemetry/4,
      {test_pid, sid}
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, sid}) end)

    {:ok, _srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: base_config(),
        store: {InMemory, store},
        registry: {Native, Native.new()},
        resume_policy: :eager,
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      )

    assert_receive {:event, :awaiting_approval, %{parked: 1, resumed: true}}, 1_000
    assert_received {:telemetry, ^sid, _, %{session_id: ^sid, resumed: true}}
  end

  test "starts under a Horde :via name and is discoverable via whereis" do
    reg = Horde.new()
    sid = "via-#{System.unique_integer([:positive])}"
    name = Horde.child_name(reg, sid)
    store = InMemory.new()

    opts = [
      session_id: sid,
      config: base_config(),
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {Normandy.Behaviours.SessionRegistry.Horde, reg},
      name: name
    ]

    # A bare start_link under a Horde :via name can lose Horde's eventually-consistent
    # registration race: OTP's gen.erl exits {:process_not_registered_via, _} when the
    # via register_name returns :no and whereis_name is not yet visible. Production never
    # hits the linked crash because it starts under the Horde DynamicSupervisor and
    # Turn.Session.start_with_retry contains+retries it. Mirror that containment here:
    # trap the exit so start_link returns the error (instead of killing us), then retry.
    Process.flag(:trap_exit, true)
    pid = start_via_with_retry(opts)

    # Horde reflects a registration through an async CRDT→ETS flush (even on a single
    # node), so poll `whereis` until the via registration is visible rather than racing
    # the flush.
    assert wait_until(fn ->
             Horde.whereis(reg, sid) == {:ok, pid}
           end)

    # Once the registration is visible, a second start for the same via name is
    # rejected (not a second live process) — exactly what the :name/via-start
    # provides over the old self-register path.
    assert {:error, {:already_started, ^pid}} =
             Normandy.Agents.Turn.Server.start_link(opts)
  end

  # Direct-start analogue of Turn.Session.start_with_retry: with trap_exit on, a via
  # registration race returns {:error, {:process_not_registered_via, _}} instead of
  # killing the caller, so we can retry until Horde's registration converges.
  defp start_via_with_retry(opts, retries \\ 50) do
    case Normandy.Agents.Turn.Server.start_link(opts) do
      {:ok, pid} ->
        pid

      # The race arrives bare or nested with the child spec.
      {:error, reason} = err ->
        if via_race?(reason) and retries > 0 do
          Process.sleep(10)
          start_via_with_retry(opts, retries - 1)
        else
          flunk("Horde via registration never converged: #{inspect(err)}")
        end
    end
  end

  defp via_race?({:process_not_registered_via, _}), do: true
  defp via_race?({{:process_not_registered_via, _}, _child}), do: true
  defp via_race?(_), do: false

  # Part B (Task 7 requirement): proves the Server threads the compacted config2
  # (returned by the compact handler) into the NEXT blocking effect, not the stale
  # pre-compaction config. A regression where the Server discards config2 and keeps
  # the old data.config would make the second call_llm see memory WITHOUT the
  # sentinel message — causing the final assertion to fail.
  test "compact handler's config2 is threaded into the subsequent LLM call by the Server" do
    store = InMemory.new()
    reg = Native.new()
    test_pid = self()
    sentinel = "__COMPACT_MARKER__"

    # Stateful call_llm: 1st call → one tool call (triggers tool batch → steering →
    # maybe_compact); 2nd call → no-tools final response. Both calls report the
    # memory they received so we can assert the sentinel is present on call #2.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn config, _state, _req ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      send(test_pid, {:llm_call, n, config.memory})

      if n == 0 do
        %Resp{
          content: "",
          tool_calls: [%ToolCall{id: "tc1", name: "weather", input: %{}}]
        }
      else
        %Resp{content: "done", tool_calls: nil}
      end
    end

    # Instrumented compact handler: appends a sentinel message to memory, returns
    # config2 (detectably different from config), and notifies the test it ran.
    compact = fn config, _turn_state, _info ->
      config2 = %{
        config
        | memory: AgentMemory.add_message(config.memory, "user", sentinel)
      }

      send(test_pid, {:compact_ran, config2.memory})
      {config2, %{compacted: true}}
    end

    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: call_llm,
        compact: compact
    }

    # Config with weather tool so the Server's internal dispatch can run it
    # (tool_registry needed: the FSM strips tool_calls when the config has no tools).
    config = %{base_config_with_tools() | max_tool_iterations: 3}

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-compact-threading",
        config: config,
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers
      )

    assert {:ok, %Resp{}} = Turn.Server.run(srv, "compact me")

    # Compact handler ran.
    assert_receive {:compact_ran, _memory}, 2_000

    # Second LLM call saw the compacted config2 (sentinel in memory).
    # If the Server had threaded the stale pre-compaction config, the sentinel
    # would be absent and this assertion would fail.
    assert_receive {:llm_call, 1, memory_at_second_call}, 2_000

    history = AgentMemory.history(memory_at_second_call)

    assert Enum.any?(history, fn msg -> msg.content == sentinel end),
           "Second LLM call did not see the compacted config2 — Server threaded stale config"
  end

  test "Tier-2 server reconstructs config from a persisted template (no :config in opts)" do
    store = InMemory.new()
    sid = "recon-#{System.unique_integer([:positive])}"

    base = base_config()

    tmpl =
      put_in(
        ConfigTemplate.from_config(base, "kind-a").behaviours_refs.credential,
        {Normandy.Test.StubCreds, []}
      )

    :ok = InMemory.save_config_template(store, sid, tmpl)

    {:ok, cat} = Catalog.start_link([])

    :ok =
      Catalog.put(cat, "kind-a", %{
        tool_registry: base.tool_registry,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _token -> base.client end
      })

    reg = Native.new()

    opts = [
      session_id: sid,
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
      template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, cat}
    ]

    assert {:ok, pid} = Normandy.Agents.Turn.Server.start_link(opts)
    assert {:ok, ^pid} = Native.whereis(reg, sid)
  end

  describe "a thin start that cannot rebuild its config" do
    defmodule FailingCreds do
      def get_token(_provider, _opts), do: {:error, :vault_sealed}
    end

    defp thin_start(creds, supplement?) do
      store = InMemory.new()
      sid = "thin-fail-#{System.unique_integer([:positive])}"
      base = base_config()

      tmpl =
        put_in(ConfigTemplate.from_config(base, "kind-a").behaviours_refs.credential, {creds, []})

      :ok = InMemory.save_config_template(store, sid, tmpl)
      {:ok, cat} = Catalog.start_link([])

      if supplement? do
        :ok =
          Catalog.put(cat, "kind-a", %{
            tool_registry: base.tool_registry,
            before_hooks: [],
            after_hooks: [],
            client_builder: fn _token -> base.client end
          })
      end

      Turn.Server.start_link(
        session_id: sid,
        store: {InMemory, store},
        registry: {Native, Native.new()},
        template_provider: {Catalog, cat}
      )
    end

    test "a template this node has no supplement for is run/2's error, not a crash" do
      assert {:ok, srv} = thin_start(Normandy.Test.StubCreds, false)
      assert {:error, {:no_template_supplement, "kind-a"}} = Turn.Server.run(srv, "hello")
    end

    test "a credential provider that fails is run/2's error, not a crash" do
      assert {:ok, srv} = thin_start(FailingCreds, true)

      assert {:error, {:credential_unavailable, FailingCreds, :vault_sealed}} =
               Turn.Server.run(srv, "hello")
    end
  end

  describe "server options saved with the template" do
    defp thin_start_with_saved_options(start_opts) do
      store = InMemory.new()
      sid = "saved-opts-#{System.unique_integer([:positive])}"
      base = base_config()

      tmpl =
        base
        |> ConfigTemplate.from_config("kind-a")
        |> put_in([:behaviours_refs, :credential], {Normandy.Test.StubCreds, []})
        |> Map.put(:server_options, %{
          approval_timeout_ms: 1_234,
          on_approval_timeout: :fail,
          idle_timeout_ms: 5_000
        })

      :ok = InMemory.save_config_template(store, sid, tmpl)
      {:ok, cat} = Catalog.start_link([])

      :ok =
        Catalog.put(cat, "kind-a", %{
          tool_registry: base.tool_registry,
          before_hooks: [],
          after_hooks: [],
          client_builder: fn _token -> base.client end
        })

      {:ok, pid} =
        Turn.Server.start_link(
          [
            session_id: sid,
            store: {InMemory, store},
            registry: {Native, Native.new()},
            template_provider: {Catalog, cat}
          ] ++ start_opts
        )

      {_state, data} = :sys.get_state(pid)
      data
    end

    test "a thin start restores them" do
      data = thin_start_with_saved_options([])

      assert data.approval_timeout_ms == 1_234
      assert data.on_approval_timeout == :fail
      assert data.idle_timeout_ms == 5_000
    end

    test "explicit start options win over the saved ones" do
      data =
        thin_start_with_saved_options(approval_timeout_ms: 99, on_approval_timeout: :continue)

      assert data.approval_timeout_ms == 99
      assert data.on_approval_timeout == :continue
      assert data.idle_timeout_ms == 5_000
    end
  end

  test "a ModelCatalogError in the compact handler fails the turn with an error reply" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn _config, _state, _req ->
      if Agent.get_and_update(counter, fn n -> {n, n + 1} end) == 0 do
        %Resp{content: "", tool_calls: [%ToolCall{id: "tc1", name: "weather", input: %{}}]}
      else
        %Resp{content: "done", tool_calls: nil}
      end
    end

    compact = fn _config, _state, _info ->
      raise Normandy.ModelCatalogError, model: "test", reason: :boom
    end

    handlers = %{
      BaseAgent.non_streaming_handlers()
      | call_llm: call_llm,
        compact: compact
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-catalog-failure",
        config: %{base_config_with_tools() | max_tool_iterations: 3},
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers
      )

    ExUnit.CaptureLog.capture_log(fn ->
      send(self(), {:result, Turn.Server.run(srv, "go")})
    end)

    assert_received {:result,
                     {:error, {:task_down, {%Normandy.ModelCatalogError{model: "test"}, _stack}}}}
  end

  describe "context window memoisation across a real turn" do
    # Three tool rounds per drive log at :info/:debug; keep the run output clean.
    @describetag :capture_log

    defmodule MemoCatalog do
      @behaviour Normandy.Behaviours.ModelCatalog

      @impl true
      def context_window(model, opts) do
        send(Keyword.fetch!(opts, :notify), {:catalog_lookup, model})
        {:ok, 200_000}
      end
    end

    # The real BaseAgent compact handler with an unpinned compactor, so every
    # steering boundary resolves the window; call_llm makes three tool rounds,
    # then answers.
    defp memo_config do
      %{
        base_config_with_tools()
        | max_tool_iterations: 5,
          behaviours: %Normandy.Behaviours.Config{
            compactor: {Normandy.Behaviours.Compactor.WindowManager, [reserved_tokens: 16]},
            model_catalog: {MemoCatalog, [notify: self()]}
          }
      }
    end

    defp three_tool_rounds do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fn _config, _state, _req ->
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        if Agent.get_and_update(counter, fn n -> {n, n + 1} end) < 3 do
          %Resp{content: "", tool_calls: [%ToolCall{id: "tc", name: "weather", input: %{}}]}
        else
          %Resp{content: "done", tool_calls: nil}
        end
      end
    end

    defp drive_once(config) do
      alias Normandy.Agents.BaseAgent

      config = BaseAgent.admit_turn_input(config, "go")

      state =
        Turn.new(
          max_iterations: config.max_tool_iterations,
          response_model: BaseAgent.turn_response_model(config),
          output_schema: config.output_schema
        )

      handlers = %{BaseAgent.non_streaming_handlers() | call_llm: three_tool_rounds()}
      {config2, _state} = Turn.Driver.drive(state, handlers, config)
      config2
    end

    test "Driver: one lookup for three steering boundaries; none on the next turn" do
      config2 = drive_once(memo_config())
      assert_received {:catalog_lookup, "test"}
      refute_received {:catalog_lookup, _}
      assert config2.resolved_context_window == {"test", 200_000}

      _config3 = drive_once(config2)
      refute_received {:catalog_lookup, _}
    end

    test "Turn.Server: one lookup for three steering boundaries in a run" do
      store = InMemory.new()
      reg = Native.new()

      handlers = %{
        BaseAgent.non_streaming_handlers()
        | call_llm: three_tool_rounds()
      }

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: "s-catalog-memo",
          config: memo_config(),
          store: {InMemory, store},
          registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
          handlers: handlers
        )

      {:ok, _} = Turn.Server.run(srv, "go")
      assert_receive {:catalog_lookup, "test"}
      refute_received {:catalog_lookup, _}
    end
  end

  def handle_telemetry(_event, measurements, metadata, {test_pid, ref}),
    do: send(test_pid, {:telemetry, ref, measurements, metadata})

  describe "failure replies and crashing callbacks (AGENTS-1)" do
    defp final_handlers(overrides \\ %{}) do
      Map.merge(
        %{
          BaseAgent.non_streaming_handlers()
          | call_llm: fn _c, _s, _r -> %Resp{content: "ok", tool_calls: nil} end
        },
        overrides
      )
    end

    defp start_server(sid, config, opts \\ []) do
      store = InMemory.new()

      base = [
        session_id: sid,
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: final_handlers()
      ]

      {:ok, srv} = Turn.Server.start_link(Keyword.merge(base, opts))
      {srv, store}
    end

    defp attach_telemetry(event) do
      ref = make_ref()

      :telemetry.attach(
        {__MODULE__, ref},
        event,
        &__MODULE__.handle_telemetry/4,
        {self(), ref}
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      ref
    end

    test "schema-invalid input replies {:rejected, ValidationError}; nothing persisted" do
      config = %{base_config() | input_schema: %RequiredQueryInput{}}
      {srv, store} = start_server("s-rej-schema", config)

      assert {:error, {:rejected, %Normandy.Schema.ValidationError{}}} =
               Turn.Server.run(srv, %{})

      assert Process.alive?(srv)
      assert {:ok, []} = InMemory.history(store, "s-rej-schema")
      assert {:ok, %Resp{content: "ok"}} = Turn.Server.run(srv, %{query: "weather"})
    end

    test "an input guardrail block replies {:rejected, ViolationError}" do
      config = %{
        base_config()
        | input_guardrails: [{Normandy.Guardrails.Builtins.MaxLength, limit: 5}]
      }

      {srv, _store} = start_server("s-rej-guard", config)

      assert {:error, {:rejected, %Normandy.Guardrails.ViolationError{}}} =
               Turn.Server.run(srv, "too long input")

      assert {:ok, %Resp{}} = Turn.Server.run(srv, "hi")
    end

    test "repeated rejected inputs do not take down Turn.Supervisor" do
      {:ok, sup} = Turn.Supervisor.start_link([])
      config = %{base_config() | input_schema: %RequiredQueryInput{}}

      {:ok, srv} =
        Turn.Supervisor.start_server(sup,
          session_id: "s-cascade",
          config: config,
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()},
          handlers: final_handlers()
        )

      for _ <- 1..5, do: assert({:error, {:rejected, _}} = Turn.Server.run(srv, %{}))

      assert Process.alive?(srv)
      assert Process.alive?(sup)
    end

    test "a raising validate handler fails the turn; the session stays usable" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      validate = fn _config, value ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0,
          do: raise("validate boom"),
          else: value
      end

      {srv, store} =
        start_server("s-crash-validate", base_config(),
          handlers: final_handlers(%{validate: validate})
        )

      log =
        capture_log(fn ->
          assert {:error, {:handler_crashed, :validate, %RuntimeError{message: "validate boom"}}} =
                   Turn.Server.run(srv, "hi")
        end)

      assert log =~ "handler :validate crashed"
      assert log =~ "validate boom"
      assert Process.alive?(srv)

      assert {:ok, %Turn.State{status: :failed}} =
               InMemory.load_turn_state(store, "s-crash-validate")

      assert {:ok, %Resp{}} = Turn.Server.run(srv, "again")
    end

    test "an exiting append handler fails the turn with the exit reason" do
      append = fn _config, _role, _content -> exit(:store_timeout) end

      {srv, _store} =
        start_server("s-crash-append", base_config(), handlers: final_handlers(%{append: append}))

      capture_log(fn ->
        assert {:error, {:handler_crashed, :append, :store_timeout}} = Turn.Server.run(srv, "hi")
      end)

      assert Process.alive?(srv)
    end

    test "the Server calls handlers.emit for each event" do
      test_pid = self()
      emit = fn _config, name, meta -> send(test_pid, {:handler_emit, name, meta}) end

      {srv, _store} =
        start_server("s-emit", base_config(), handlers: final_handlers(%{emit: emit}))

      assert {:ok, %Resp{}} = Turn.Server.run(srv, "hi")
      assert_received {:handler_emit, :iteration, %{iteration: 1, final: false}}
    end

    test "a nil handlers.emit is skipped" do
      {srv, _store} =
        start_server("s-emit-nil", base_config(), handlers: final_handlers(%{emit: nil}))

      assert {:ok, %Resp{}} = Turn.Server.run(srv, "hi")
    end

    test "a raising subscriber is logged and reported; the turn still succeeds" do
      ref = attach_telemetry([:normandy, :turn, :subscriber, :exception])

      log =
        capture_log(fn ->
          {srv, _store} =
            start_server("s-sub-raise", base_config(),
              subscriber: fn _name, _meta -> raise "subscriber boom" end
            )

          assert {:ok, %Resp{}} = Turn.Server.run(srv, "hi")
        end)

      assert log =~ "subscriber crashed"
      assert log =~ "subscriber boom"

      assert_received {:telemetry, ^ref, %{count: 1},
                       %{session_id: "s-sub-raise", event: :iteration, kind: :error}}
    end

    test "a subscriber that exits or throws does not fail the turn" do
      ref = attach_telemetry([:normandy, :turn, :subscriber, :exception])

      subscribers = [
        {"s-sub-exit", :exit, fn _name, _meta -> exit(:gone) end},
        {"s-sub-throw", :throw, fn _name, _meta -> throw(:nope) end}
      ]

      for {sid, kind, sub} <- subscribers do
        capture_log(fn ->
          {srv, _store} = start_server(sid, base_config(), subscriber: sub)
          assert {:ok, %Resp{}} = Turn.Server.run(srv, "hi")
        end)

        assert_received {:telemetry, ^ref, %{count: 1}, %{session_id: ^sid, kind: ^kind}}
      end
    end

    test "a MatchError crash logs the exception type but never the matched value" do
      validate = fn _config, _value ->
        {:ok, _} = Enum.at([{:error, %{secret: "SENTINEL-123"}}], 0)
      end

      {srv, _store} =
        start_server("s-crash-secret", base_config(),
          handlers: final_handlers(%{validate: validate})
        )

      log =
        capture_log(fn ->
          assert {:error, {:handler_crashed, :validate, %MatchError{}}} =
                   Turn.Server.run(srv, "hi")
        end)

      assert log =~ "MatchError"
      refute log =~ "SENTINEL-123"
    end

    test "an exit with a tuple term logs the tag but not the payload" do
      append = fn _config, _role, _content ->
        exit({:timeout, {GenServer, :call, [self(), "SENTINEL-456", 5000]}})
      end

      {srv, _store} =
        start_server("s-exit-secret", base_config(), handlers: final_handlers(%{append: append}))

      log =
        capture_log(fn ->
          assert {:error, {:handler_crashed, :append, {:timeout, _}}} = Turn.Server.run(srv, "hi")
        end)

      assert log =~ "{:timeout, ...}"
      refute log =~ "SENTINEL-456"
    end
  end

  describe "approval expiry" do
    defp billing_approval_policy do
      %Normandy.Behaviours.Config{
        policy:
          {Normandy.Behaviours.PolicyEngine.Ruleset,
           rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
           default_action: :allow}
      }
    end

    # 1st LLM call → weather (allowed) + billing (parked); later calls → final "done".
    # Each call reports {:llm_call, n, messages} so tests can inspect what the model saw.
    defp start_approval_server(sid, extra) do
      store = InMemory.new()
      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      call_llm = fn config, _s, _r ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        send(test_pid, {:llm_call, n, AgentMemory.messages(config.memory)})

        if n == 0 do
          %Resp{
            content: "",
            tool_calls: [
              %ToolCall{id: "ok1", name: "weather", input: %{}},
              %ToolCall{id: "pk1", name: "billing", input: %{}}
            ]
          }
        else
          %Resp{content: "done", tool_calls: nil}
        end
      end

      opts = [
        session_id: sid,
        config: %{config_with_notify(test_pid) | behaviours: billing_approval_policy()},
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm},
        approval_timeout_ms: 50,
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      ]

      {:ok, srv} = Turn.Server.start_link(Keyword.merge(opts, extra))
      {srv, store}
    end

    defp run_async(srv, input) do
      parent = self()
      spawn(fn -> send(parent, {:run_result, Turn.Server.run(srv, input)}) end)
    end

    test "default :continue tells the model the approval timed out" do
      ref = attach_telemetry([:normandy, :turn, :approval, :expired])
      {srv, _store} = start_approval_server("s-exp-continue", [])

      run_async(srv, "go")

      assert_receive {:run_result, {:ok, %Resp{content: "done"}}}, 2_000
      assert_received {:event, :approval_expired, %{expired: 1, mode: :continue}}

      assert_received {:telemetry, ^ref, %{count: 1},
                       %{
                         session_id: "s-exp-continue",
                         mode: :continue,
                         timeout_ms: 50,
                         tool_names: ["billing"]
                       }}

      assert_received {:llm_call, 1, messages}

      assert Enum.any?(
               messages,
               &match?(
                 %Message{
                   role: "tool",
                   content: %ToolResult{
                     tool_call_id: "pk1",
                     output: %{
                       expired: true,
                       error: "approval timed out: no approver responded within 50ms"
                     }
                   }
                 },
                 &1
               )
             )

      refute_received {:tool_ran, "billing"}
    end

    test ":fail ends the turn with {:approval_timeout, ids}; a late approval is dropped" do
      {srv, store} = start_approval_server("s-exp-fail", on_approval_timeout: :fail)

      run_async(srv, "go")

      assert_receive {:run_result, {:error, {:approval_timeout, ["pk1"]}}}, 2_000
      assert_received {:event, :approval_expired, %{expired: 1, mode: :fail}}
      refute_received {:llm_call, 1, _}

      {:ok, entries} = InMemory.history(store, "s-exp-fail")
      answered = for %{role: "tool", content: %ToolResult{tool_call_id: id}} <- entries, do: id
      assert Enum.sort(answered) == ["ok1", "pk1"]

      assert {:ok, %Turn.State{status: :failed, error: {:approval_timeout, ["pk1"]}}} =
               InMemory.load_turn_state(store, "s-exp-fail")

      :ok = Turn.Server.approve(srv, %{"pk1" => :approve})
      assert {:ok, %Resp{content: "done"}} = Turn.Server.run(srv, "again")
      refute_received {:tool_ran, "billing"}
    end

    test "an approval that arrives in time is not expired while the approved tool runs" do
      test_pid = self()

      config = %{
        base_config()
        | tool_registry:
            Normandy.Tools.Registry.new([
              %FakeTool{name: "weather", notify: test_pid},
              %FakeTool{name: "billing", notify: test_pid, sleep_ms: 1500}
            ]),
          behaviours: billing_approval_policy()
      }

      {srv, _store} =
        start_approval_server("s-exp-intime", config: config, approval_timeout_ms: 500)

      run_async(srv, "go")
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
      :ok = Turn.Server.approve(srv, %{"pk1" => :approve})

      assert_receive {:run_result, {:ok, %Resp{content: "done"}}}, 5_000
      assert_received {:tool_ran, "billing"}
      refute_received {:event, :approval_expired, _}
    end

    test "each expired call emits [:normandy, :tool, :denied] with reason :approval_expired" do
      ref = attach_telemetry([:normandy, :tool, :denied])
      {srv, _store} = start_approval_server("s-denied-expired", [])

      run_async(srv, "go")

      assert_receive {:run_result, {:ok, %Resp{content: "done"}}}, 2_000

      assert_received {:telemetry, ^ref, %{count: 1},
                       %{
                         session_id: "s-denied-expired",
                         tool_name: "billing",
                         tool_call_id: "pk1",
                         reason: :approval_expired
                       }}

      refute_received {:telemetry, ^ref, _, %{session_id: "s-denied-expired"}}
    end

    test "each rejected call emits [:normandy, :tool, :denied] with reason :approval_rejected" do
      ref = attach_telemetry([:normandy, :tool, :denied])

      {srv, _store} =
        start_approval_server("s-denied-rejected", approval_timeout_ms: 5_000)

      run_async(srv, "go")
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
      :ok = Turn.Server.approve(srv, %{"pk1" => :reject})

      assert_receive {:run_result, {:ok, %Resp{content: "done"}}}, 2_000

      assert_received {:telemetry, ^ref, %{count: 1},
                       %{
                         session_id: "s-denied-rejected",
                         tool_name: "billing",
                         tool_call_id: "pk1",
                         reason: :approval_rejected
                       }}

      refute_received {:telemetry, ^ref, _, %{session_id: "s-denied-rejected"}}
    end

    test "an approval cast without an approver context (older sender) is still handled" do
      {_s, stop_ref, _r, _e, _} = attach_approval_span("s-alegacy")
      {srv, _store} = start_approval_server("s-alegacy", approval_timeout_ms: 5_000)

      run_async(srv, "go")
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
      :ok = :gen_statem.cast(srv, {:approval, %{"pk1" => :approve}})

      assert_receive {:run_result, {:ok, %Resp{content: "done"}}}, 2_000
      assert_received {:tool_ran, "billing"}
      assert_received {:telemetry, ^stop_ref, _, %{outcome: :approved}}
    end

    defp attach_approval_span(sid) do
      start_ref = attach_telemetry([:normandy, :turn, :approval, :start])
      stop_ref = attach_telemetry([:normandy, :turn, :approval, :stop])
      run_ref = attach_telemetry([:normandy, :agent, :run, :stop])
      exc_ref = attach_telemetry([:normandy, :agent, :run, :exception])
      {start_ref, stop_ref, run_ref, exc_ref, sid}
    end

    test "approval span: duration covers the park, run stop carries approval_wait" do
      {start_ref, stop_ref, run_ref, _exc, _} = attach_approval_span("s-aspan")
      {srv, _store} = start_approval_server("s-aspan", approval_timeout_ms: 5_000)

      run_async(srv, "go")
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
      Process.sleep(100)
      :ok = Turn.Server.approve(srv, %{"pk1" => :approve})
      assert_receive {:run_result, {:ok, %Resp{content: "done"}}}, 2_000

      assert_received {:telemetry, ^start_ref, %{system_time: st, monotonic_time: _},
                       %{
                         session_id: "s-aspan",
                         tool_names: ["billing"],
                         count: 1,
                         telemetry_span_context: ctx
                       }}

      assert is_integer(st)

      assert_received {:telemetry, ^stop_ref, %{duration: d, monotonic_time: _},
                       %{
                         session_id: "s-aspan",
                         outcome: :approved,
                         tool_names: ["billing"],
                         count: 1,
                         telemetry_span_context: ^ctx
                       }}

      assert System.convert_time_unit(d, :native, :millisecond) >= 100

      assert_received {:telemetry, ^run_ref, %{approval_wait: wait, duration: run_d},
                       %{session_id: "s-aspan"}}

      assert wait == d
      assert run_d >= wait
    end

    test "outcome is :rejected when the decision rejects every call" do
      {_s, stop_ref, _r, _e, _} = attach_approval_span("s-arej")
      {srv, _store} = start_approval_server("s-arej", approval_timeout_ms: 5_000)

      run_async(srv, "go")
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
      :ok = Turn.Server.approve(srv, %{"pk1" => :reject})
      assert_receive {:run_result, {:ok, _}}, 2_000

      assert_received {:telemetry, ^stop_ref, %{duration: _}, %{outcome: :rejected}}
    end

    test "outcome is :expired on expiry, alongside the aggregate expired event" do
      {_s, stop_ref, run_ref, _e, _} = attach_approval_span("s-aexp")
      {srv, _store} = start_approval_server("s-aexp", [])

      run_async(srv, "go")
      assert_receive {:run_result, {:ok, _}}, 2_000

      assert_received {:telemetry, ^stop_ref, %{duration: d}, %{outcome: :expired}}
      assert System.convert_time_unit(d, :native, :millisecond) >= 40

      assert_received {:telemetry, ^run_ref, %{approval_wait: ^d}, %{session_id: "s-aexp"}}
    end

    test "outcome is :mixed when some calls are approved and others rejected" do
      {_s, stop_ref, _r, _e, _} = attach_approval_span("s-amix")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      call_llm = fn _c, _s, _r ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if n == 0 do
          %Resp{
            content: "",
            tool_calls: [
              %ToolCall{id: "pk1", name: "billing", input: %{}},
              %ToolCall{id: "pk2", name: "billing", input: %{}}
            ]
          }
        else
          %Resp{content: "done", tool_calls: nil}
        end
      end

      {srv, _store} =
        start_approval_server("s-amix",
          approval_timeout_ms: 5_000,
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
        )

      run_async(srv, "go")
      assert_receive {:event, :awaiting_approval, %{parked: 2}}, 2_000
      :ok = Turn.Server.approve(srv, %{"pk1" => :approve, "pk2" => :reject})
      assert_receive {:run_result, {:ok, _}}, 2_000

      assert_received {:telemetry, ^stop_ref, _, %{outcome: :mixed, count: 2}}
    end

    test "approval_wait sums every park in the turn" do
      {_s, stop_ref, run_ref, _e, _} = attach_approval_span("s-atwice")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      call_llm = fn _c, _s, _r ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if n < 2 do
          %Resp{
            content: "",
            tool_calls: [%ToolCall{id: "pk#{n}", name: "billing", input: %{}}]
          }
        else
          %Resp{content: "done", tool_calls: nil}
        end
      end

      {srv, _store} =
        start_approval_server("s-atwice",
          approval_timeout_ms: 5_000,
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
        )

      run_async(srv, "go")
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
      Process.sleep(50)
      :ok = Turn.Server.approve(srv, %{"pk0" => :approve})
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
      Process.sleep(50)
      :ok = Turn.Server.approve(srv, %{"pk1" => :approve})
      assert_receive {:run_result, {:ok, _}}, 2_000

      assert_received {:telemetry, ^stop_ref, %{duration: d1}, %{outcome: :approved}}
      assert_received {:telemetry, ^stop_ref, %{duration: d2}, %{outcome: :approved}}
      assert_received {:telemetry, ^run_ref, %{approval_wait: wait}, %{session_id: "s-atwice"}}
      assert wait == d1 + d2
      assert System.convert_time_unit(wait, :native, :millisecond) >= 100
    end

    test "a turn that never parks has approval_wait 0 and no approval span" do
      {start_ref, _stop, run_ref, _e, _} = attach_approval_span("s-anone")
      {srv, _store} = start_server("s-anone", base_config())
      assert {:ok, _} = Turn.Server.run(srv, "go")

      assert_received {:telemetry, ^run_ref, %{approval_wait: 0}, %{session_id: "s-anone"}}
      refute_received {:telemetry, ^start_ref, _, %{session_id: "s-anone"}}
    end

    test "terminating while parked closes the approval span with :terminated before the run exception" do
      Process.flag(:trap_exit, true)
      {_s, stop_ref, _r, exc_ref, _} = attach_approval_span("s-aterm")
      {srv, _store} = start_approval_server("s-aterm", approval_timeout_ms: 5_000)

      run_async(srv, "go")
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
      :ok = :gen_statem.stop(srv, :shutdown, 5_000)

      assert_receive {:telemetry, ^stop_ref, %{duration: _}, %{outcome: :terminated}}, 1_000

      assert_receive {:telemetry, ^exc_ref, %{approval_wait: w},
                      %{session_id: "s-aterm", kind: :exit}},
                     1_000

      assert w > 0
    end

    test "an invalid :on_approval_timeout raises ArgumentError naming the key and value" do
      assert_raise ArgumentError,
                   ~r/Turn\.Server\.start_link\/1: invalid :on_approval_timeout, expected :continue or :fail, got: :sometimes/,
                   fn ->
                     Turn.Server.start_link(
                       session_id: "s-bad-opt",
                       config: base_config(),
                       store: {InMemory, InMemory.new()},
                       registry: {Native, Native.new()},
                       on_approval_timeout: :sometimes
                     )
                   end
    end
  end

  describe "dangling tool_use repair" do
    defp dangling_memory(ids) do
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "charge me")
      |> AgentMemory.add_message("assistant", %Resp{
        content: "",
        tool_calls: Enum.map(ids, &%ToolCall{id: &1, name: "billing", input: %{}})
      })
    end

    # Store and memory both end in a tool_use with no result, as after a crash.
    defp start_dangling_server(sid, config_overrides, handler_overrides \\ %{}, opts \\ []) do
      store = InMemory.new()
      memory = dangling_memory(Keyword.get(opts, :calls, ["t1"]))

      # With :fail_append_at the server writes through a wrapper whose Nth append
      # (counted after this seeding) fails once.
      {store_mod, server_store} =
        case Keyword.get(opts, :fail_append_at) do
          nil ->
            {InMemory, store}

          n ->
            {_, counter, _} = FlakyAppendStore.new(n)
            {FlakyAppendStore, {store, counter, n}}
        end

      for %Message{role: role, content: content} <- AgentMemory.messages(memory) do
        {:ok, _} =
          InMemory.append_entry(store, sid, %AgentMemory.Entry{
            turn_id: "live",
            role: role,
            content: content
          })
      end

      # The server reads its turn state from the store, so seed it there.
      {turn_state, server_opts} = Keyword.pop(Keyword.get(opts, :server_opts, []), :turn_state)
      if turn_state, do: :ok = InMemory.save_turn_state(store, sid, turn_state)

      test_pid = self()

      call_llm = fn config, _s, _r ->
        send(test_pid, {:llm_messages, AgentMemory.messages(config.memory)})
        %Resp{content: "ok", tool_calls: nil}
      end

      handlers =
        Map.merge(%{BaseAgent.non_streaming_handlers() | call_llm: call_llm}, handler_overrides)

      {:ok, srv} =
        [
          session_id: sid,
          config: Map.merge(%{base_config() | memory: memory}, config_overrides),
          store: {store_mod, server_store},
          registry: {Native, Native.new()},
          handlers: handlers
        ]
        |> Keyword.merge(server_opts)
        |> Turn.Server.start_link()

      {srv, store}
    end

    test "the next turn closes the unanswered tool_use before the user message" do
      {srv, store} = start_dangling_server("s-dangling", %{})

      log =
        capture_log(fn ->
          assert {:ok, %Resp{content: "ok"}} = Turn.Server.run(srv, "next")
        end)

      assert log =~ "interrupted"
      assert log =~ "billing"
      assert_received {:llm_messages, messages}

      assert [
               %Message{role: "user", content: "charge me"},
               %Message{role: "assistant"},
               %Message{
                 role: "tool",
                 content: %ToolResult{
                   tool_call_id: "t1",
                   is_error: true,
                   output: %{
                     interrupted: true,
                     error:
                       "tool call interrupted: the previous turn ended before a result was " <>
                         "recorded; the tool may or may not have run"
                   }
                 }
               },
               %Message{role: "user", content: "next"}
             ] = messages

      {:ok, entries} = InMemory.history(store, "s-dangling")
      assert ["user", "assistant", "tool", "user", "assistant"] = Enum.map(entries, & &1.role)
    end

    test "a repaired batch is not repaired again on the following turn" do
      {srv, store} = start_dangling_server("s-dangling-once", %{})

      capture_log(fn ->
        assert {:ok, _} = Turn.Server.run(srv, "next")
        assert {:ok, _} = Turn.Server.run(srv, "again")
      end)

      {:ok, entries} = InMemory.history(store, "s-dangling-once")
      assert Enum.count(entries, &(&1.role == "tool")) == 1
    end

    test "a rejected input in a dangling session changes nothing" do
      {srv, store} =
        start_dangling_server("s-dangling-reject", %{input_schema: %RequiredQueryInput{}})

      assert {:error, {:rejected, _}} = Turn.Server.run(srv, %{})
      {:ok, entries} = InMemory.history(store, "s-dangling-reject")
      assert Enum.map(entries, & &1.role) == ["user", "assistant"]
    end

    test "an append crash during repair replies {:handler_crashed, :append, _}; nothing persisted" do
      {srv, store} =
        start_dangling_server("s-dangling-crash", %{}, %{
          append: fn _config, _role, _content -> raise "append boom" end
        })

      capture_log(fn ->
        assert {:error, {:handler_crashed, :append, %RuntimeError{message: "append boom"}}} =
                 Turn.Server.run(srv, "next")
      end)

      assert Process.alive?(srv)
      {:ok, entries} = InMemory.history(store, "s-dangling-crash")
      assert Enum.map(entries, & &1.role) == ["user", "assistant"]
    end

    test "a user-message write failure after a repair keeps memory in step with the store" do
      # Appends: 1 = interrupted t1 (ok), 2 = user message (fails), then all succeed.
      {srv, store} = start_dangling_server("s-dangling-ufail", %{}, %{}, fail_append_at: 2)

      capture_log(fn ->
        assert {:error, {:persist_failed, :disk_full}} = Turn.Server.run(srv, "next")
        assert {:ok, _} = Turn.Server.run(srv, "again")
      end)

      {:ok, entries} = InMemory.history(store, "s-dangling-ufail")
      tools = Enum.filter(entries, &(&1.role == "tool"))
      assert [%{content: %ToolResult{tool_call_id: "t1"}}] = tools
    end

    test "a partial write failure in a batch of two repairs only the remainder later" do
      # Appends: 1 = interrupted t1 (ok), 2 = interrupted t2 (fails), then all succeed.
      {srv, store} =
        start_dangling_server("s-dangling-partial", %{}, %{},
          calls: ["t1", "t2"],
          fail_append_at: 2
        )

      capture_log(fn ->
        assert {:error, {:persist_failed, :disk_full}} = Turn.Server.run(srv, "next")
        assert {:ok, _} = Turn.Server.run(srv, "again")
      end)

      {:ok, entries} = InMemory.history(store, "s-dangling-partial")

      ids =
        for %{role: "tool", content: %ToolResult{tool_call_id: id}} <- entries, do: id

      assert Enum.sort(ids) == ["t1", "t2"]
    end

    test "a failed tool-result write mid-batch leaves memory matching the store; the next turn closes it" do
      # Appends: 1 = user, 2 = assistant tool_use (c1, c2), 3 = tool result c1 (fails once).
      store = InMemory.new()
      {_, counter, _} = FlakyAppendStore.new(3)
      sid = "s-tool-write-fail"

      {:ok, llm_calls} = Agent.start_link(fn -> 0 end)

      call_llm = fn _config, _s, _r ->
        case Agent.get_and_update(llm_calls, &{&1, &1 + 1}) do
          0 ->
            %Resp{
              content: "",
              tool_calls: [
                %ToolCall{id: "c1", name: "weather", input: %{}},
                %ToolCall{id: "c2", name: "weather", input: %{}}
              ]
            }

          _ ->
            %Resp{content: "done", tool_calls: nil}
        end
      end

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: sid,
          config: base_config_with_tools(),
          store: {FlakyAppendStore, {store, counter, 3}},
          registry: {Native, Native.new()},
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
        )

      capture_log(fn ->
        assert {:error, {:persist_failed, :disk_full}} = Turn.Server.run(srv, "go")
        assert {:ok, %Resp{content: "done"}} = Turn.Server.run(srv, "again")
      end)

      {:ok, entries} = InMemory.history(store, sid)

      results =
        for %{role: "tool", content: %ToolResult{tool_call_id: id} = r} <- entries, do: {id, r}

      assert results |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["c1", "c2"]

      assert {_, %ToolResult{output: %{interrupted: true}}} =
               Enum.find(results, &(elem(&1, 0) == "c1"))
    end

    defp parked_or_steering(status) do
      call = %ToolCall{id: "t1", name: "billing", input: %{}}

      base = %Turn.State{
        status: status,
        iterations_left: 4,
        max_iterations: 5,
        response_model: %Resp{},
        output_schema: %Resp{}
      }

      if status == :awaiting_approval,
        do: %{base | pending_calls: [call], parked_calls: [call], held_results: []},
        else: base
    end

    defp tool_ids(store, sid) do
      {:ok, entries} = InMemory.history(store, sid)
      for %{role: "tool", content: %ToolResult{tool_call_id: id}} <- entries, do: id
    end

    test "an eagerly resumed :steering turn closes the unanswered tool_use before the LLM call" do
      sid = "s-resume-dangling"

      {_srv, store} =
        start_dangling_server(sid, %{}, %{},
          server_opts: [turn_state: parked_or_steering(:steering), resume_policy: :eager]
        )

      assert_receive {:llm_messages, messages}, 1_000

      assert [
               %Message{role: "user", content: "charge me"},
               %Message{role: "assistant"},
               %Message{
                 role: "tool",
                 content: %ToolResult{tool_call_id: "t1", output: %{interrupted: true}}
               }
             ] = messages

      assert tool_ids(store, sid) == ["t1"]
    end

    test "an append crash while repairing a resumed turn fails it without calling the LLM" do
      sid = "s-resume-dangling-crash"

      {srv, store} =
        start_dangling_server(
          sid,
          %{},
          %{append: fn _config, _role, _content -> raise "append boom" end},
          server_opts: [turn_state: parked_or_steering(:steering), resume_policy: :eager]
        )

      :sys.get_state(srv)
      refute_received {:llm_messages, _}

      assert {:ok,
              %Turn.State{
                status: :failed,
                error: {:handler_crashed, :append, %RuntimeError{message: "append boom"}}
              }} = InMemory.load_turn_state(store, sid)

      assert tool_ids(store, sid) == []
      assert Process.alive?(srv)
    end

    test "a resumed parked turn is not repaired (its calls await a decision)" do
      sid = "s-resume-parked-dangling"

      {srv, store} =
        start_dangling_server(sid, %{}, %{},
          server_opts: [turn_state: parked_or_steering(:awaiting_approval), resume_policy: :eager]
        )

      :sys.get_state(srv)
      assert {:awaiting_approval, _} = :sys.get_state(srv)
      assert tool_ids(store, sid) == []
    end
  end

  describe "store unavailable at start" do
    alias Normandy.Test.FlakyStore

    defp flaky_server(store, sid, extra \\ []) do
      handlers = %{
        BaseAgent.non_streaming_handlers()
        | call_llm: fn _config, _state, _req -> %Resp{content: "hi", tool_calls: nil} end
      }

      Turn.Server.start_link(
        [
          session_id: sid,
          config: base_config(),
          store: {FlakyStore, store},
          registry: {Native, Native.new()},
          handlers: handlers
        ] ++ extra
      )
    end

    test "stray messages in :unavailable do not crash the server" do
      store = FlakyStore.new()
      FlakyStore.down(store)
      {:ok, srv} = flaky_server(store, "s-stray-unavail")
      assert {:unavailable, _} = :sys.get_state(srv)

      Enum.each([:stray, {make_ref(), :late}, {:DOWN, make_ref(), :process, self(), :x}], fn m ->
        send(srv, m)
      end)

      assert {:unavailable, _} = :sys.get_state(srv)
      assert {:error, :store_down} = Turn.Server.run(srv, "hello")
    end

    test "the start succeeds and run/2 replies the store's reason" do
      store = FlakyStore.new()
      FlakyStore.down(store)

      assert {:ok, srv} = flaky_server(store, "s-unavail")
      assert {:error, :store_down} = Turn.Server.run(srv, "hello")
      assert Process.alive?(srv)
    end

    test "a call after the store recovers loads the session and runs the turn" do
      store = FlakyStore.new()
      FlakyStore.down(store)
      {:ok, srv} = flaky_server(store, "s-recover-call")
      assert {:error, :store_down} = Turn.Server.run(srv, "hello")

      FlakyStore.up(store)

      assert {:ok, %Resp{content: "hi"}} = Turn.Server.run(srv, "hello")
    end

    test "the server retries the load on its own once the store is back" do
      store = FlakyStore.new()
      FlakyStore.down(store)
      {:ok, srv} = flaky_server(store, "s-recover-timer")
      assert {:unavailable, _} = :sys.get_state(srv)

      FlakyStore.up(store)

      assert wait_until(fn -> match?({:idle, _}, :sys.get_state(srv)) end)
    end

    test "with no call for idle_timeout_ms, it stops normally" do
      store = FlakyStore.new()
      FlakyStore.down(store)
      Process.flag(:trap_exit, true)
      {:ok, srv} = flaky_server(store, "s-unavail-idle", idle_timeout_ms: 50)

      assert_receive {:EXIT, ^srv, :normal}, 1_000
    end

    test "a crash while the store is down does not take the supervisor or other sessions down" do
      store = FlakyStore.new()
      {:ok, sup} = Turn.Supervisor.start_link(max_restarts: 3, max_seconds: 5)
      reg = Native.new()

      start = fn sid ->
        Turn.Supervisor.start_server(sup,
          session_id: sid,
          config: base_config(),
          store: {FlakyStore, store},
          registry: {Native, reg}
        )
      end

      {:ok, a} = start.("s-storm-a")
      {:ok, b} = start.("s-storm-b")
      sup_ref = Process.monitor(sup)

      FlakyStore.down(store)
      Process.exit(a, :kill)

      assert wait_until(fn ->
               match?({:ok, pid} when pid != a, Native.whereis(reg, "s-storm-a"))
             end)

      refute_received {:DOWN, ^sup_ref, _, _, _}
      assert Process.alive?(sup)
      assert Process.alive?(b)
    end
  end
end
