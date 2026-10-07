defmodule Normandy.Hooks.RunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Hooks.{Context, Runner}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.{Probe, TurnEndOnly}
  alias Normandy.Test.OwnLog
  alias Normandy.Test.TelemetryCapture

  defmodule EchoOpts do
    @moduledoc false
    use Normandy.Behaviours.Hooks

    @impl true
    def on_passivate(_ctx, opts) do
      send(opts[:notify], {:opts, opts})
      :ok
    end
  end

  defp config(hooks, name \\ "runner-agent") do
    %{
      name: name,
      model: "m",
      session_id: "s",
      tool_context: %{u: 1},
      behaviours: %{hooks: hooks}
    }
  end

  defp probe(tag, opts \\ []), do: {Probe, [notify: TestHooks.sink(), tag: tag] ++ opts}
  defp call, do: %ToolCall{id: "c1", name: "t", input: %{"a" => 1}}
  defp result, do: %ToolResult{tool_call_id: "c1", output: "ok", is_error: false}
  defp info, do: %{final: false, iterations_left: 3}

  # Every message in the mailbox, in arrival order.
  defp mailbox do
    receive do
      msg -> [msg | mailbox()]
    after
      0 -> []
    end
  end

  describe "entries/1, hooks?/1, handles?/2" do
    test "read behaviours.hooks, else []" do
      assert Runner.entries(config([{Probe, []}])) == [{Probe, []}]
      assert Runner.entries(%{behaviours: nil}) == []
      assert Runner.entries(%{}) == []
      refute Runner.hooks?(config([]))
      assert Runner.hooks?(config([{TurnEndOnly, []}]))
      assert Runner.handles?(config([{TurnEndOnly, []}]), :on_turn_end)
      refute Runner.handles?(config([{TurnEndOnly, []}]), :on_prompt)
    end

    test "handles?/2 treats a module that is not loaded as not handling: no raise, no log" do
      log =
        capture_log(fn ->
          refute Runner.handles?(config([{Does.Not.Exist, []}]), :before_llm)
          refute Runner.handles?(config([{Does.Not.Exist, []}]), :on_turn_end)
          assert Runner.handles?(config([{Does.Not.Exist, []}, {Probe, []}]), :before_llm)
        end)

      refute log =~ "Does.Not.Exist"
    end
  end

  describe "chains" do
    test "no entries passes the value through" do
      config = config([])
      assert Runner.prompt(config, "hi") == {:cont, "hi"}
      assert Runner.before_llm(config, info()) == :cont
      assert Runner.before_tool(config, call()) == {:cont, call()}
      assert Runner.after_tool(config, call(), result()) == result()
      assert Runner.after_compact(config, [], %{}) == []
      assert Runner.session_start(config) == []
      assert Runner.passivate(config) == :ok
      assert Runner.turn_end(config, {:ok, 1}) == :ok
    end

    test "entries run in order; a rewrite is what the next entry receives" do
      config = config([probe(:a, returns: [on_prompt: {:cont, "rewritten"}]), probe(:b)])
      assert Runner.prompt(config, "hi") == {:cont, "rewritten"}

      assert [
               {:hook, :a, :on_prompt, ["hi", %Context{event: :on_prompt, turn_id: nil}]},
               {:hook, :b, :on_prompt, ["rewritten", _ctx]}
             ] = mailbox()
    end

    test "the first halt stops the chain and names the hook" do
      assert Runner.prompt(
               config([probe(:a, returns: [on_prompt: {:halt, "no"}]), probe(:b)]),
               "hi"
             ) ==
               {:halt, Probe, "no"}

      refute_received {:hook, :b, _, _}

      llm = config([probe(:a, returns: [before_llm: {:halt, "budget"}]), probe(:b)])
      assert Runner.before_llm(llm, info()) == {:halt, Probe, "budget"}
      refute_received {:hook, :b, :before_llm, _}
    end

    test "a before_tool halt with a reason becomes a denial answering the call" do
      tool = config([probe(:a, returns: [before_tool: {:halt, "blocked"}]), probe(:b)])

      assert Runner.before_tool(tool, call()) ==
               {:halt,
                %ToolResult{
                  tool_call_id: "c1",
                  output: %{
                    error:
                      "This call was blocked by a hook: blocked. " <>
                        "Do not retry it; continue without it or tell the user.",
                    denied: true
                  },
                  is_error: true
                }}

      refute_received {:hook, :b, :before_tool, _}
    end

    test "a before_tool halt with a %ToolResult{} is returned as given" do
      denied = %ToolResult{tool_call_id: "c1", output: %{error: "custom"}, is_error: true}
      tool = config([probe(:a, returns: [before_tool: {:halt, denied}])])
      assert Runner.before_tool(tool, call()) == {:halt, denied}
    end

    test "after_tool threads rewritten results" do
      rewritten = %{result() | output: "redacted"}
      config = config([probe(:a, returns: [after_tool: {:cont, rewritten}]), probe(:b)])
      assert Runner.after_tool(config, call(), result()) == rewritten
      assert_received {:hook, :b, :after_tool, [_call, ^rewritten, _ctx]}
    end

    test "inject results are concatenated in list order; [] and other values inject nothing" do
      config =
        config([
          probe(:a,
            returns: [after_compact: {:inject, ["one"]}, on_session_start: {:inject, ["s1"]}]
          ),
          probe(:b, returns: [after_compact: {:inject, []}]),
          probe(:c, returns: [after_compact: {:inject, ["two", "three"]}]),
          probe(:d, returns: [after_compact: {:ok, 3}])
        ])

      dropped = [%Entry{id: "e1", role: "user", content: "old"}]

      assert Runner.after_compact(config, dropped, %{compacted: true}) == ["one", "two", "three"]
      assert_received {:hook, :b, :after_compact, [^dropped, %{compacted: true}, _]}
      assert Runner.session_start(config) == ["s1"]
    end

    test "an entry without the event's callback is skipped" do
      config = config([{TurnEndOnly, notify: TestHooks.sink()}])
      assert Runner.prompt(config, "hi") == {:cont, "hi"}
      assert Runner.turn_end(config, {:ok, :r}) == :ok
      assert_received {:turn_end_only, {:ok, :r}}
    end

    test "the context carries the event, agent name, model, session and values" do
      Runner.passivate(config([probe(:a)]))
      assert_received {:hook, :a, :on_passivate, [ctx]}

      assert %Context{
               event: :on_passivate,
               agent_name: "runner-agent",
               model: "m",
               session_id: "s",
               values: %{u: 1},
               turn_id: nil
             } = ctx
    end

    test ":on_error is removed from opts before the callback sees them" do
      sink = TestHooks.sink()
      Runner.passivate(config([{EchoOpts, notify: sink, on_error: :open, label: "x"}]))
      assert_received {:opts, opts}
      assert Enum.sort(opts) == Enum.sort(notify: sink, label: "x")
    end

    test "a module that is not loaded raises, except on logged-only events" do
      config = config([{Nope.Missing, []}])

      assert_raise ArgumentError, "hook module Nope.Missing is not available", fn ->
        Runner.prompt(config, "hi")
      end

      log = capture_log(fn -> assert Runner.turn_end(config, {:ok, 1}) == :ok end)
      assert log =~ "hook module Nope.Missing is not available"
    end
  end

  describe ":on_error" do
    test ":reraise (default) propagates raise, exit and throw" do
      assert_raise RuntimeError, "boom", fn ->
        Runner.prompt(config([probe(:a, returns: [on_prompt: {:raise, "boom"}])]), "x")
      end

      assert catch_exit(
               Runner.before_llm(
                 config([probe(:a, returns: [before_llm: {:exit, :down}])]),
                 info()
               )
             ) == :down

      assert catch_throw(
               Runner.after_compact(
                 config([probe(:a, returns: [after_compact: {:throw, :t}])]),
                 [],
                 %{}
               )
             ) == :t
    end

    # The Runner logs in the caller, so these refutes read only this process's events:
    # an async capture_log also sees other tests' lines (ResumeReaperTest logs `:boom`).
    test ":open logs the hook, event and exception module, not the message, and passes the value on" do
      config =
        config([probe(:a, on_error: :open, returns: [on_prompt: {:raise, "boom"}]), probe(:b)])

      log = OwnLog.capture(fn -> assert Runner.prompt(config, "hi") == {:cont, "hi"} end)
      assert log =~ "hook Normandy.Test.Hooks.Probe on_prompt crashed: RuntimeError"
      refute log =~ "boom"
      assert_received {:hook, :b, :on_prompt, ["hi", _]}

      exit_log =
        OwnLog.capture(fn ->
          assert Runner.after_compact(
                   config([
                     probe(:a, on_error: :open, returns: [after_compact: {:exit, {:secret, 1}}])
                   ]),
                   [],
                   %{}
                 ) == []
        end)

      assert exit_log =~ "after_compact crashed: exit"
      refute exit_log =~ "secret"
    end

    @tag :capture_log
    test ":closed halts a haltable event with a reason naming the hook, not the message" do
      assert {:halt, Probe, reason} =
               Runner.prompt(
                 config([probe(:a, on_error: :closed, returns: [on_prompt: {:raise, "boom"}])]),
                 "hi"
               )

      assert reason == "hook Normandy.Test.Hooks.Probe crashed: RuntimeError"

      tool = config([probe(:a, on_error: :closed, returns: [before_tool: {:throw, :t}])])

      assert {:halt,
              %ToolResult{tool_call_id: "c1", is_error: true, output: %{error: msg, denied: true}}} =
               Runner.before_tool(tool, call())

      assert msg ==
               "This call was blocked by a hook: hook Normandy.Test.Hooks.Probe crashed: " <>
                 "throw. Do not retry it; continue without it or tell the user."
    end

    @tag :capture_log
    test ":closed on after_tool replaces the result with an error result" do
      config =
        config([probe(:a, on_error: :closed, returns: [after_tool: {:raise, "redactor down"}])])

      assert %ToolResult{tool_call_id: "c1", is_error: true, output: %{error: msg}} =
               Runner.after_tool(config, call(), result())

      assert msg == "hook Normandy.Test.Hooks.Probe crashed: RuntimeError"
    end

    test ":open on before_tool and after_tool logs and passes the value on" do
      tool =
        config([probe(:a, on_error: :open, returns: [before_tool: {:raise, "boom"}]), probe(:b)])

      log = OwnLog.capture(fn -> assert Runner.before_tool(tool, call()) == {:cont, call()} end)
      assert log =~ "before_tool crashed: RuntimeError"
      refute log =~ "boom"
      assert_received {:hook, :b, :before_tool, [_call, _ctx]}

      after_tool =
        config([probe(:a, on_error: :open, returns: [after_tool: {:raise, "boom"}]), probe(:b)])

      log =
        OwnLog.capture(fn ->
          assert Runner.after_tool(after_tool, call(), result()) == result()
        end)

      assert log =~ "after_tool crashed: RuntimeError"
      refute log =~ "boom"
      assert_received {:hook, :b, :after_tool, [_call, _result, _ctx]}
    end

    @tag :capture_log
    test ":closed on before_llm halts with a reason naming the hook" do
      llm =
        config([probe(:a, on_error: :closed, returns: [before_llm: {:raise, "boom"}]), probe(:b)])

      assert Runner.before_llm(llm, info()) ==
               {:halt, Probe, "hook Normandy.Test.Hooks.Probe crashed: RuntimeError"}

      refute_received {:hook, :b, :before_llm, _}
    end

    @tag :capture_log
    test ":closed after_tool crash answers the call and skips the later after_tool entries" do
      config =
        config([
          probe(:a, on_error: :closed, returns: [after_tool: {:raise, "down"}]),
          probe(:b)
        ])

      assert %ToolResult{is_error: true} = Runner.after_tool(config, call(), result())
      assert_received {:hook, :a, :after_tool, _}
      refute_received {:hook, :b, :after_tool, _}
    end

    test ":closed on after_compact and on_session_start re-raises" do
      assert_raise RuntimeError, "boom", fn ->
        Runner.after_compact(
          config([probe(:a, on_error: :closed, returns: [after_compact: {:raise, "boom"}])]),
          [],
          %{}
        )
      end

      assert_raise RuntimeError, "boom", fn ->
        Runner.session_start(
          config([probe(:a, on_error: :closed, returns: [on_session_start: {:raise, "boom"}])])
        )
      end
    end

    @tag :capture_log
    test "logged-only events never raise, whatever :on_error says" do
      for policy <- [:reraise, :open, :closed] do
        assert Runner.turn_end(
                 config([probe(:a, on_error: policy, returns: [on_turn_end: {:raise, "late"}])]),
                 {:ok, 1}
               ) == :ok

        assert Runner.passivate(
                 config([probe(:a, on_error: policy, returns: [on_passivate: {:exit, :late}])])
               ) == :ok
      end
    end
  end

  describe "return contract" do
    test "a consumed value outside the contract raises ArgumentError even under :open" do
      assert_raise ArgumentError,
                   ~r/expected Normandy.Test.Hooks.Probe.on_prompt\/3 to return .*, got: :yes/,
                   fn ->
                     Runner.prompt(
                       config([probe(:a, on_error: :open, returns: [on_prompt: :yes])]),
                       "hi"
                     )
                   end

      error =
        assert_raise ArgumentError, fn ->
          Runner.after_compact(
            config([probe(:a, returns: [after_compact: {:inject, "not a list"}])]),
            [],
            %{}
          )
        end

      assert error.message =~ "got: {:inject, a string (10 bytes)}"
      refute error.message =~ "not a list"

      assert_raise ArgumentError, ~r/before_tool\/3 to return/, fn ->
        Runner.before_tool(config([probe(:a, returns: [before_tool: {:halt, 42}])]), call())
      end

      assert_raise ArgumentError, ~r/before_llm\/3 to return/, fn ->
        Runner.before_llm(config([probe(:a, returns: [before_llm: {:cont, info()}])]), info())
      end
    end

    test "logged-only events ignore their return value" do
      assert Runner.turn_end(config([probe(:a, returns: [on_turn_end: :done])]), {:ok, 1}) == :ok
      assert Runner.passivate(config([probe(:a, returns: [on_passivate: {:error, :x}])])) == :ok
    end

    test "every event has a contract description" do
      for {event, _arity} <- Hooks.events(), do: assert(is_binary(Runner.contract(event)))
    end

    test "the test Probe implements every event" do
      # function_exported?/3 is false for a module not loaded yet (test order decides).
      Code.ensure_loaded!(Probe)
      for {event, arity} <- Hooks.events(), do: assert(function_exported?(Probe, event, arity))
    end
  end

  describe "telemetry" do
    test "one span per entry call with event, hook and result, in call order" do
      name = "runner-telemetry-#{System.unique_integer([:positive])}"

      TelemetryCapture.attach_span(
        [[:normandy, :hook, :start], [:normandy, :hook, :stop]],
        agent_name: name
      )

      config = config([probe(:a, returns: [on_prompt: {:cont, "new"}]), probe(:b)], name)
      Runner.prompt(config, "hi")

      spans = for {:span, event, meta} <- mailbox(), do: {List.last(event), meta}

      assert [
               {:start, %{event: :on_prompt, hook: Probe}},
               {:stop, %{event: :on_prompt, hook: Probe, result: :rewrite}},
               {:start, %{event: :on_prompt, hook: Probe}},
               {:stop, %{event: :on_prompt, hook: Probe, result: :cont}}
             ] = spans

      Runner.before_llm(config([probe(:a, returns: [before_llm: {:halt, "x"}])], name), info())
      assert_received {:span, [:normandy, :hook, :stop], %{event: :before_llm, result: :halt}}

      Runner.after_compact(
        config([probe(:a, returns: [after_compact: {:inject, ["t"]}])], name),
        [],
        %{}
      )

      assert_received {:span, [:normandy, :hook, :stop],
                       %{event: :after_compact, result: :inject}}

      Runner.turn_end(config([probe(:a)], name), {:ok, 1})
      assert_received {:span, [:normandy, :hook, :stop], %{event: :on_turn_end, result: :ok}}
    end

    test "tool events carry the call id and tool name" do
      name = "runner-telemetry-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach_span([[:normandy, :hook, :stop]], agent_name: name)

      Runner.after_tool(config([probe(:a)], name), call(), result())

      assert_received {:span, [:normandy, :hook, :stop],
                       %{event: :after_tool, tool_call_id: "c1", tool: "t", result: :cont}}
    end

    @tag :capture_log
    test "a rescued crash stops with result: :rescued; a re-raised one emits :exception" do
      name = "runner-telemetry-#{System.unique_integer([:positive])}"

      TelemetryCapture.attach_span(
        [[:normandy, :hook, :stop], [:normandy, :hook, :exception]],
        agent_name: name
      )

      Runner.turn_end(config([probe(:a, returns: [on_turn_end: {:raise, "x"}])], name), {:ok, 1})
      assert_received {:span, [:normandy, :hook, :stop], %{event: :on_turn_end, result: :rescued}}

      catch_error(
        Runner.prompt(config([probe(:a, returns: [on_prompt: {:raise, "x"}])], name), "hi")
      )

      assert_received {:span, [:normandy, :hook, :exception],
                       %{event: :on_prompt, kind: :error, stacktrace: []}}
    end

    test "a return-contract violation emits :exception and no :stop" do
      name = "runner-contract-#{System.unique_integer([:positive])}"

      TelemetryCapture.attach_span(
        [[:normandy, :hook, :stop], [:normandy, :hook, :exception]],
        agent_name: name
      )

      assert_raise ArgumentError, fn ->
        Runner.prompt(
          config([probe(:a, on_error: :open, returns: [on_prompt: :yes])], name),
          "hi"
        )
      end

      assert_received {:span, [:normandy, :hook, :exception], %{event: :on_prompt}}
      refute_received {:span, [:normandy, :hook, :stop], _}
    end

    test "the Normandy.Telemetry moduledoc names every hook event" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Normandy.Telemetry)
      assert doc =~ "[:normandy, :hook, :start | :stop | :exception]"
      for {event, _arity} <- Hooks.events(), do: assert(doc =~ ":#{event}")
    end
  end
end
