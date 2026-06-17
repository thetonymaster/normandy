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
end
