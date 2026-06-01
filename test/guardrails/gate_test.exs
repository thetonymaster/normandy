defmodule Normandy.Guardrails.GateTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema}
  alias Normandy.Guardrails.Builtins.LlmRelevanceGuard.Decision
  alias Normandy.Guardrails.Gate
  alias NormandyTest.Support.RelevanceMock

  defp agent_with(response, extra \\ %{}) do
    BaseAgent.init(
      Map.merge(
        %{
          client: %RelevanceMock{response: response},
          model: "claude-haiku-4-5-20251001",
          temperature: 0.0
        },
        extra
      )
    )
  end

  describe "allow path" do
    test "on-topic messages are delegated to BaseAgent.run/2" do
      agent = agent_with(%Decision{on_topic: true})

      {_updated, response} =
        Gate.run(agent, "help me plan my wedding",
          relevance: [domain: "event planning"],
          redirect_message: "I can only help with events"
        )

      # The agent turn runs against the output schema; RelevanceMock returns it
      # unchanged (ModelMockup behaviour), proving delegation happened.
      assert response == %BaseAgentOutputSchema{}
    end
  end
end
