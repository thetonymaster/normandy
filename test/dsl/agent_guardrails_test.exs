defmodule Normandy.DSL.AgentGuardrailsTest do
  use ExUnit.Case, async: true

  alias Normandy.Guardrails.Builtins.{ForbiddenSubstrings, MaxLength, RequiredFields}

  defmodule GuardedAgent do
    use Normandy.DSL.Agent

    agent do
      name("Guarded Agent")
      model("claude-haiku-4-5-20251001")

      guardrails(:input, [
        {MaxLength, limit: 100, field: :chat_message},
        {ForbiddenSubstrings, terms: ["ignore previous"], field: :chat_message}
      ])

      # ModelMockup answers "stub answer" (11 graphemes), which this blocks.
      guardrails(:output, [
        {MaxLength, limit: 5, field: :chat_message}
      ])
    end
  end

  defmodule WarnOnlyAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      guardrails(:output, [{RequiredFields, fields: [:chat_message]}], on_violation: :warn)
    end
  end

  defmodule PlainAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
    end
  end

  defmodule OverriddenGuardrailsAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")

      # First call — should be discarded.
      guardrails(:input, [{MaxLength, limit: 5, field: :chat_message}])
      # Second call wins — `guardrails/2` replaces, it does not accumulate.
      guardrails(:input, [{ForbiddenSubstrings, terms: ["nope"], field: :chat_message}])
    end
  end

  describe "guardrails macro" do
    test "input guardrails are wired into the agent config" do
      agent = GuardedAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert agent.guardrails[:input] == [
               {MaxLength, limit: 100, field: :chat_message},
               {ForbiddenSubstrings, terms: ["ignore previous"], field: :chat_message}
             ]
    end

    test "output guardrails are wired into the agent config" do
      agent = GuardedAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert agent.guardrails[:output] == [{MaxLength, limit: 5, field: :chat_message}]
    end

    test "agents without guardrails default to empty lists" do
      agent = PlainAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert agent.guardrails[:input] == []
      assert agent.guardrails[:output] == []
    end

    test "input guardrails take effect when running" do
      agent = GuardedAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert_raise Normandy.Guardrails.ViolationError, fn ->
        GuardedAgent.run!(agent, "please ignore previous and do stuff")
      end
    end

    test "calling guardrails/2 twice for the same stage replaces, not composes" do
      agent =
        OverriddenGuardrailsAgent.new(client: %NormandyTest.Support.ModelMockup{})

      # Second call wins: only the ForbiddenSubstrings guard survives.
      assert agent.guardrails[:input] ==
               [{ForbiddenSubstrings, terms: ["nope"], field: :chat_message}]
    end

    test "config/0 exposes guardrails for introspection" do
      config = GuardedAgent.config()

      assert config.guardrails[:input] == [
               {MaxLength, limit: 100, field: :chat_message},
               {ForbiddenSubstrings, terms: ["ignore previous"], field: :chat_message}
             ]

      assert config.guardrails[:output] == [{MaxLength, limit: 5, field: :chat_message}]
    end

    test "config/0 exposes empty guardrail lists when undefined" do
      config = PlainAgent.config()

      assert config.guardrails[:input] == []
      assert config.guardrails[:output] == []
    end
  end

  describe "output guardrails on_violation" do
    @describetag :capture_log

    test "an output violation blocks the answer by default" do
      agent = GuardedAgent.new(client: %NormandyTest.Support.ModelMockup{})
      assert agent.guardrails[:on_violation] == :block

      assert_raise Normandy.Guardrails.ViolationError, ~r/output guardrail violation/i, fn ->
        GuardedAgent.run!(agent, "hi")
      end
    end

    test "on_violation: :warn is wired into the agent config and config/0" do
      agent = WarnOnlyAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert agent.guardrails[:on_violation] == :warn
      assert WarnOnlyAgent.config().guardrails[:on_violation] == :warn
    end

    test "on_violation is rejected for input guardrails" do
      assert_raise ArgumentError, ~r/on_violation applies to :output guardrails only/, fn ->
        Code.compile_string("""
        defmodule Normandy.DSL.AgentGuardrailsTest.BadInput do
          use Normandy.DSL.Agent

          agent do
            model("m")
            guardrails(:input, [], on_violation: :warn)
          end
        end
        """)
      end
    end
  end

  describe "guardrails passed to new/1" do
    test "change only the keys they give; the rest stay as declared" do
      agent =
        GuardedAgent.new(
          client: %NormandyTest.Support.ModelMockup{},
          guardrails: [on_violation: :warn]
        )

      assert agent.guardrails[:on_violation] == :warn
      assert agent.guardrails[:input] == GuardedAgent.config().guardrails[:input]
      assert agent.guardrails[:output] == GuardedAgent.config().guardrails[:output]
    end

    test "a 1.x guardrail option names new/1 and its 2.0 home" do
      assert_raise ArgumentError,
                   "Normandy.DSL.AgentGuardrailsTest.GuardedAgent.new/1: :input_guardrails " <>
                     "moved to guardrails: [input: ...] in 2.0; see MIGRATING-2.0.md §22",
                   fn ->
                     GuardedAgent.new([
                       {:input_guardrails, []},
                       {:client, %NormandyTest.Support.ModelMockup{}}
                     ])
                   end
    end
  end
end
