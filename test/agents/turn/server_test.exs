defmodule Normandy.Agents.Turn.ServerTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.ToolCall

  # A response model the FSM finalizes on: no tool_calls → :completed.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Parameterized fake tool for testing tool dispatch/classification.
  # `notify` is a pid that receives `{:tool_ran, name}` when the tool runs,
  # letting tests assert whether a tool was executed or silently rejected.
  defmodule FakeTool do
    use Normandy.Schema

    schema do
      field(:name, :string)
      field(:notify, :any, default: nil)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.Turn.ServerTest.FakeTool do
    def tool_name(t), do: t.name
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}

    def run(t) do
      if t.notify, do: send(t.notify, {:tool_ran, t.name})
      {:ok, "ran #{t.name}"}
    end
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
      memory: Normandy.Components.AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: Normandy.Components.AgentMemory.new_memory(),
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
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    # Inject a fake LLM via the :handlers override (test seam, see Step 3).
    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
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

  test "a completed turn persists a terminal :stopped turn state (for the resume reaper)" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
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
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
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

  test "a batch with a needs_approval call parks the turn (:awaiting_approval) and persists" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()
    test_pid = self()

    # First LLM response asks for two tool calls; classify parks one of them.
    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
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

  test "approving a parked call resumes the turn and finalizes" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()
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

    handlers = %{Normandy.Agents.BaseAgent.non_streaming_handlers() | call_llm: call_llm}

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
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-idle",
        config: base_config(),
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: %{
          Normandy.Agents.BaseAgent.non_streaming_handlers()
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
    reg = Normandy.Behaviours.SessionRegistry.Native.new()
    parent = self()

    # Blocking call_llm that signals the test when it has started, then sleeps
    # to keep the server :running while the second turn request arrives.
    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r ->
          send(parent, :llm_started)
          Process.sleep(150)
          %Resp{content: "x"}
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
    assert_receive :llm_started, 1_000
    # Second turn: arrives while server is :running → postponed, replayed on :idle entry.
    spawn(fn -> send(parent, {:b, Turn.Server.run(srv, "second")}) end)

    assert_receive {:a, {:ok, %Resp{}}}, 2_000
    assert_receive {:b, {:ok, %Resp{}}}, 2_000
  end

  test "stale/late approval cast in :idle state does not crash the server" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()
    parent = self()

    # Stateful call_llm: 1st call (turn "go") → two tool calls; 2nd call → final;
    # 3rd call (turn "again") → final with no tools.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn _c, _s, _r ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      cond do
        n == 0 ->
          %Resp{
            content: "",
            tool_calls: [
              %ToolCall{id: "ok1", name: "weather", input: %{}},
              %ToolCall{id: "pk1", name: "billing", input: %{}}
            ]
          }

        true ->
          %Resp{content: "done", tool_calls: nil}
      end
    end

    handlers = %{Normandy.Agents.BaseAgent.non_streaming_handlers() | call_llm: call_llm}

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
      def load_turn_state(_handle, _sid), do: {:error, :not_found}

      @impl true
      def append_entry(_handle, _sid, _entry), do: {:error, :disk_full}

      @impl true
      def history(_handle, _sid), do: {:ok, []}

      @impl true
      def fork(_handle, _sid, _new_sid), do: {:error, :nope}
    end

    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
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
    reg = Normandy.Behaviours.SessionRegistry.Native.new()
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

    handlers = %{Normandy.Agents.BaseAgent.non_streaming_handlers() | call_llm: call_llm}

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

  test "starts under a Horde :via name and is discoverable via whereis" do
    reg = Normandy.Behaviours.SessionRegistry.Horde.new()
    sid = "via-#{System.unique_integer([:positive])}"
    name = Normandy.Behaviours.SessionRegistry.Horde.child_name(reg, sid)
    store = Normandy.Behaviours.SessionStore.InMemory.new()

    opts = [
      session_id: sid,
      config: base_config(),
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {Normandy.Behaviours.SessionRegistry.Horde, reg},
      name: name
    ]

    assert {:ok, pid} = Normandy.Agents.Turn.Server.start_link(opts)
    assert {:ok, ^pid} = Normandy.Behaviours.SessionRegistry.Horde.whereis(reg, sid)

    # The via name registers atomically at start: a second start for the same
    # session is rejected (not a second live process), which is exactly what the
    # :name/via-start provides over the old self-register path.
    assert {:error, {:already_started, ^pid}} =
             Normandy.Agents.Turn.Server.start_link(opts)
  end

  # Part B (Task 7 requirement): proves the Server threads the compacted config2
  # (returned by the compact handler) into the NEXT blocking effect, not the stale
  # pre-compaction config. A regression where the Server discards config2 and keeps
  # the old data.config would make the second call_llm see memory WITHOUT the
  # sentinel message — causing the final assertion to fail.
  test "compact handler's config2 is threaded into the subsequent LLM call by the Server" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()
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
        | memory: Normandy.Components.AgentMemory.add_message(config.memory, "user", sentinel)
      }

      send(test_pid, {:compact_ran, config2.memory})
      {config2, %{compacted: true}}
    end

    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
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

    history = Normandy.Components.AgentMemory.history(memory_at_second_call)

    assert Enum.any?(history, fn msg -> msg.content == sentinel end),
           "Second LLM call did not see the compacted config2 — Server threaded stale config"
  end

  test "Tier-2 server reconstructs config from a persisted template (no :config in opts)" do
    store = Normandy.Behaviours.SessionStore.InMemory.new()
    sid = "recon-#{System.unique_integer([:positive])}"

    base = base_config()

    tmpl =
      put_in(
        Normandy.Agents.ConfigTemplate.from_config(base, "kind-a").behaviours_refs.credential,
        {Normandy.Test.StubCreds, []}
      )

    :ok = Normandy.Behaviours.SessionStore.InMemory.save_config_template(store, sid, tmpl)

    {:ok, cat} = Normandy.Behaviours.AgentTemplate.Catalog.start_link([])

    :ok =
      Normandy.Behaviours.AgentTemplate.Catalog.put(cat, "kind-a", %{
        tool_registry: base.tool_registry,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _token -> base.client end
      })

    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    opts = [
      session_id: sid,
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
      template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, cat}
    ]

    assert {:ok, pid} = Normandy.Agents.Turn.Server.start_link(opts)
    assert {:ok, ^pid} = Normandy.Behaviours.SessionRegistry.Native.whereis(reg, sid)
  end
end
