defmodule Normandy.DSL.AgentHooksTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Config
  alias Normandy.Test.Hooks.{Probe, TurnEndOnly}

  defmodule HookedAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      hooks([{Normandy.Test.Hooks.Probe, tag: :dsl, on_error: :open}])
    end
  end

  defmodule PlainAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
    end
  end

  defp client, do: %NormandyTest.Support.ModelMockup{}

  test "declared hooks reach the agent's behaviours and config/0" do
    agent = HookedAgent.new(client: client())
    assert agent.behaviours.hooks == [{Probe, tag: :dsl, on_error: :open}]
    assert HookedAgent.config().hooks == [{Probe, tag: :dsl, on_error: :open}]
  end

  test "declared hooks run before hooks given at runtime" do
    agent =
      HookedAgent.new(client: client(), behaviours: %Config{hooks: [{TurnEndOnly, []}]})

    assert agent.behaviours.hooks == [{Probe, tag: :dsl, on_error: :open}, {TurnEndOnly, []}]
  end

  test "an agent without hooks keeps behaviours nil, as before" do
    agent = PlainAgent.new(client: client())
    assert agent.behaviours == nil
    assert PlainAgent.config().hooks == []
  end

  test "a malformed literal declaration fails at compile time" do
    assert_raise ArgumentError, ~r/invalid :on_error/, fn ->
      Code.compile_string("""
      defmodule Normandy.DSL.AgentHooksTest.BadOnError do
        use Normandy.DSL.Agent

        agent do
          model("m")
          hooks([{Normandy.Test.Hooks.Probe, on_error: :sometimes}])
        end
      end
      """)
    end

    assert_raise ArgumentError, ~r/invalid hook entry/, fn ->
      Code.compile_string("""
      defmodule Normandy.DSL.AgentHooksTest.BadShape do
        use Normandy.DSL.Agent

        agent do
          model("m")
          hooks([Normandy.Test.Hooks.Probe])
        end
      end
      """)
    end
  end

  test "a second hooks declaration fails at compile time" do
    assert_raise ArgumentError, ~r/hooks\/1 is declared twice/, fn ->
      Code.compile_string("""
      defmodule Normandy.DSL.AgentHooksTest.Twice do
        use Normandy.DSL.Agent

        agent do
          model("m")
          hooks([{Normandy.Test.Hooks.Probe, []}])
          hooks([{Normandy.Test.Hooks.TurnEndOnly, []}])
        end
      end
      """)
    end
  end

  test "a module that does not exist fails at new/1" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Normandy.DSL.AgentHooksTest.MissingModule do
        use Normandy.DSL.Agent

        agent do
          model("m")
          hooks([{Normandy.DSL.AgentHooksTest.NoSuchHook, []}])
        end
      end
      """)

    assert_raise ArgumentError, ~r/hook module .*NoSuchHook is not available/, fn ->
      mod.new(client: client())
    end
  end

  test "a non-literal declaration skips the compile-time check and fails at new/1" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Normandy.DSL.AgentHooksTest.NonLiteral do
        use Normandy.DSL.Agent

        agent do
          model("m")
          hooks(List.wrap({Normandy.Test.Hooks.Probe, on_error: :sometimes}))
        end
      end
      """)

    assert_raise ArgumentError, ~r/invalid :on_error/, fn ->
      mod.new(client: client())
    end
  end
end
