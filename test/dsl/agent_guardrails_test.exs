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

      guardrails(:output, [
        {RequiredFields, fields: [:chat_message]}
      ])
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
      {:ok, agent} = GuardedAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert agent.input_guardrails == [
               {MaxLength, limit: 100, field: :chat_message},
               {ForbiddenSubstrings, terms: ["ignore previous"], field: :chat_message}
             ]
    end

    test "output guardrails are wired into the agent config" do
      {:ok, agent} = GuardedAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert agent.output_guardrails == [{RequiredFields, fields: [:chat_message]}]
    end

    test "agents without guardrails default to empty lists" do
      {:ok, agent} = PlainAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert agent.input_guardrails == []
      assert agent.output_guardrails == []
    end

    test "input guardrails take effect when running" do
      {:ok, agent} = GuardedAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert_raise Normandy.Guardrails.ViolationError, fn ->
        GuardedAgent.run(agent, "please ignore previous and do stuff")
      end
    end

    test "calling guardrails/2 twice for the same stage replaces, not composes" do
      {:ok, agent} =
        OverriddenGuardrailsAgent.new(client: %NormandyTest.Support.ModelMockup{})

      # Second call wins: only the ForbiddenSubstrings guard survives.
      assert agent.input_guardrails ==
               [{ForbiddenSubstrings, terms: ["nope"], field: :chat_message}]
    end
  end
end
