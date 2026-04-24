defmodule Normandy.DSL.AgentStreamingGuardrailsTest do
  use ExUnit.Case, async: true

  alias Normandy.Guardrails.Builtins.ForbiddenSubstrings

  defmodule IncrementalAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")

      guardrails(:output, [
        {ForbiddenSubstrings, terms: ["badword"]}
      ])

      streaming_mode(:incremental)
      streaming_chunk_size(128)
    end
  end

  defmodule DefaultStreamingAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
    end
  end

  describe "streaming_mode / streaming_chunk_size macros" do
    test "wire incremental mode and chunk size into the agent config" do
      {:ok, agent} = IncrementalAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert agent.output_guardrails_streaming_mode == :incremental
      assert agent.output_guardrails_chunk_size == 128
    end

    test "defaults apply when macros are omitted" do
      {:ok, agent} = DefaultStreamingAgent.new(client: %NormandyTest.Support.ModelMockup{})

      assert agent.output_guardrails_streaming_mode == :accumulate
      assert agent.output_guardrails_chunk_size == 200
    end

    test "config/0 exposes streaming guardrail settings" do
      config = IncrementalAgent.config()

      assert config.output_guardrails_streaming_mode == :incremental
      assert config.output_guardrails_chunk_size == 128
    end

    test "config/0 defaults are exposed when macros omitted" do
      config = DefaultStreamingAgent.config()

      assert config.output_guardrails_streaming_mode == :accumulate
      assert config.output_guardrails_chunk_size == 200
    end
  end
end
