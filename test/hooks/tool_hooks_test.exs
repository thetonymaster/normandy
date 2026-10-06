defmodule Normandy.Hooks.ToolHooksTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Dispatch}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Test.{ContextProbe, ScriptedToolClient, TelemetryCapture}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.{Probe, TurnEndOnly}

  defmodule OverBudget do
    @moduledoc false
    @behaviour Normandy.Behaviours.BudgetTracker
    @impl true
    def check(_scope, _call, _opts), do: {:error, :cap_exceeded}
    @impl true
    def record(_scope, _call, _result, _opts), do: :ok
  end

  defmodule NeedsApproval do
    @moduledoc false
    @behaviour Normandy.Behaviours.PolicyEngine
    @impl true
    def check(_call, _ctx), do: {:needs_approval, %{reason: "human review"}}
  end

  defp call(name \\ "probe"), do: %ToolCall{id: "call_1", name: name, input: %{}}

  defp agent(behaviours, name \\ "tool-hooks-agent") do
    %{client: %ScriptedToolClient{}, model: "test", name: name, behaviours: behaviours}
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%ContextProbe{notify: self()})
  end

  defp dispatch(agent, call \\ call()),
    do: Dispatch.dispatch_one(agent, call, BaseAgent.base_agent_pipeline(agent))

  defp probe(tag, opts \\ []), do: {Probe, [notify: TestHooks.sink(), tag: tag] ++ opts}

  test "no tool callbacks: the pipeline is exactly what it was before hooks" do
    f = fn _config, call -> {:cont, call} end
    pipeline = Config.to_pipeline(%Config{before_hooks: [f], hooks: [{TurnEndOnly, []}]})

    assert pipeline.before_hooks == [f]
    assert pipeline.after_hooks == []
    assert pipeline.after_tool == nil
  end

  test "module before_tool runs first; its rewrite reaches the function hooks" do
    test_pid = self()
    rewritten = %ToolCall{call() | input: %{"redacted" => true}}

    fun_hook = fn _config, call ->
      send(test_pid, {:fun_before, call.input})
      {:cont, call}
    end

    behaviours = %Config{
      hooks: [probe(:m, returns: [before_tool: {:cont, rewritten}])],
      before_hooks: [fun_hook]
    }

    assert %ToolResult{is_error: false} = dispatch(agent(behaviours))
    assert_received {:hook, :m, :before_tool, [%ToolCall{input: seen}, _ctx]}
    assert seen == %{}
    assert_received {:fun_before, %{"redacted" => true}}
  end

  test "a module halt skips later modules and the function hooks, emitting one denial" do
    test_pid = self()
    name = "tool-hooks-halt-#{System.unique_integer([:positive])}"
    ref = TelemetryCapture.attach([[:normandy, :tool, :denied]], agent_name: name)

    fun_hook = fn _config, call ->
      send(test_pid, :fun_ran)
      {:cont, call}
    end

    behaviours = %Config{
      hooks: [probe(:first, returns: [before_tool: {:halt, "blocked"}]), probe(:second)],
      before_hooks: [fun_hook]
    }

    assert %ToolResult{
             tool_call_id: "call_1",
             is_error: true,
             output: %{
               error:
                 "This call was blocked by a hook: blocked. " <>
                   "Do not retry it; continue without it or tell the user.",
               denied: true
             }
           } = dispatch(agent(behaviours, name))

    refute_received {:hook, :second, :before_tool, _}
    refute_received :fun_ran
    refute_received {:probe_ctx, _}
    assert_received {:telemetry, ^ref, %{count: 1}, %{reason: :hook_halt}}
    refute_received {:telemetry, ^ref, _, _}
  end

  test "module after_tool runs before the function after-hooks; its rewrite reaches them" do
    test_pid = self()
    from_module = %ToolResult{tool_call_id: "call_1", output: "from-module", is_error: false}

    fun_hook = fn _config, _call, result ->
      send(test_pid, {:fun_after, result.output})
      %{result | output: "from-function"}
    end

    behaviours = %Config{
      hooks: [probe(:m, returns: [after_tool: {:cont, from_module}])],
      after_hooks: [fun_hook]
    }

    assert %ToolResult{output: "from-function"} = dispatch(agent(behaviours))
    assert_received {:hook, :m, :after_tool, [_call, %ToolResult{output: original}, _ctx]}
    assert original == "ns=nil"
    assert_received {:fun_after, "from-module"}
  end

  describe "a hook-built result JSON cannot express" do
    alias Normandy.Components.{AgentMemory, BaseIOSchema}

    # The result is an error naming the type, and it still goes to memory and
    # back out as the model's JSON: the turn continues.
    defp assert_safe_error(%ToolResult{} = result, type) do
      assert %ToolResult{is_error: true, output: error} = result
      assert error == "the tool ran, but its output cannot be sent as JSON: it contains #{type}"

      memory = AgentMemory.add_message(AgentMemory.new_memory(), "tool", result)
      assert [%{content: _}] = AgentMemory.history(memory)
      assert [%{content: content}] = BaseIOSchema.to_json(result)
      assert is_binary(content)
    end

    test "a module after_tool output with a tuple" do
      built = %ToolResult{tool_call_id: "call_1", output: {:ok, 1}, is_error: false}
      behaviours = %Config{hooks: [probe(:m, returns: [after_tool: {:cont, built}])]}

      assert_safe_error(dispatch(agent(behaviours)), "a tuple")
    end

    test "a function after-hook output that is a keyword list" do
      hook = fn _config, _call, result -> %{result | output: [error: "x"]} end
      behaviours = %Config{after_hooks: [hook]}

      assert_safe_error(dispatch(agent(behaviours)), "a tuple")
    end

    test "a module before_tool halt result with a tuple" do
      built = %ToolResult{tool_call_id: "call_1", output: {:x, 1}, is_error: true}
      behaviours = %Config{hooks: [probe(:m, returns: [before_tool: {:halt, built}])]}

      assert_safe_error(dispatch(agent(behaviours)), "a tuple")
    end
  end

  test "a policy denial passes after_tool once and the function after-hooks not at all" do
    test_pid = self()

    behaviours = %Config{
      policy:
        {Normandy.Behaviours.PolicyEngine.Ruleset,
         rules: [%{match: "probe", action: :deny, rule_id: "R1"}], default_action: :allow},
      hooks: [probe(:m)],
      after_hooks: [
        fn _config, _call, result ->
          send(test_pid, :fun_after)
          result
        end
      ]
    }

    assert %ToolResult{tool_call_id: "call_1", is_error: true, output: %{denied: true}} =
             dispatch(agent(behaviours))

    assert_received {:hook, :m, :after_tool,
                     [%ToolCall{id: "call_1"}, %ToolResult{is_error: true}, _ctx]}

    refute_received {:hook, :m, :after_tool, _}
    refute_received :fun_after
  end

  test "a registry miss passes after_tool" do
    assert %ToolResult{tool_call_id: "call_1", is_error: true} =
             dispatch(agent(%Config{hooks: [probe(:m)]}), call("nope"))

    assert_received {:hook, :m, :after_tool,
                     [%ToolCall{name: "nope"}, %ToolResult{is_error: true}, _ctx]}
  end

  test "an executed call passes after_tool exactly once" do
    assert %ToolResult{tool_call_id: "call_1", is_error: false} =
             dispatch(agent(%Config{hooks: [probe(:m)]}))

    assert_received {:hook, :m, :after_tool, [_call, %ToolResult{is_error: false}, _ctx]}
    refute_received {:hook, :m, :after_tool, _}
  end

  test "a budget denial passes after_tool once and never executes the tool" do
    behaviours = %Config{budget: {OverBudget, []}, hooks: [probe(:m)]}

    assert %ToolResult{tool_call_id: "call_1", is_error: true} = dispatch(agent(behaviours))

    assert_received {:hook, :m, :after_tool, [_call, %ToolResult{is_error: true}, _ctx]}
    refute_received {:hook, :m, :after_tool, _}
    refute_received {:probe_ctx, _}
  end

  test "a needs_approval verdict collapses to a pending denial that passes after_tool once" do
    behaviours = %Config{policy: {NeedsApproval, []}, hooks: [probe(:m)]}

    assert %ToolResult{tool_call_id: "call_1", is_error: true, output: %{denied: true}} =
             dispatch(agent(behaviours))

    assert_received {:hook, :m, :after_tool, [_call, %ToolResult{is_error: true}, _ctx]}
    refute_received {:hook, :m, :after_tool, _}
    refute_received {:probe_ctx, _}
  end

  test "after_tool cannot change which call a result answers" do
    other = %ToolResult{tool_call_id: "other", output: "x", is_error: false}
    behaviours = %Config{hooks: [probe(:m, returns: [after_tool: {:cont, other}])]}
    assert %ToolResult{tool_call_id: "call_1", output: "x"} = dispatch(agent(behaviours))
  end

  test "init/1 rejects malformed hooks and opts that are not plain data" do
    assert_raise ArgumentError, ~r/invalid :on_error/, fn ->
      agent(%Config{hooks: [{Probe, on_error: :sometimes}]})
    end

    assert_raise ArgumentError, ~r/hook module Nope.Missing is not available/, fn ->
      agent(%Config{hooks: [{Nope.Missing, []}]})
    end

    assert_raise ArgumentError, ~r/must be plain data/, fn ->
      agent(%Config{hooks: [{Probe, notify: self()}]})
    end
  end
end
