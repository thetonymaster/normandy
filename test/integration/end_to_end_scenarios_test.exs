defmodule Normandy.Integration.EndToEndScenariosTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Batch.Processor
  alias Normandy.Coordination.{SequentialOrchestrator, ParallelOrchestrator}
  alias NormandyTest.Support.IntegrationHelper

  @moduletag :integration
  @moduletag :api
  @moduletag timeout: 180_000

  setup do
    # These tests require a real API key
    # Skip by running: mix test --exclude api
    agent = IntegrationHelper.create_real_agent(temperature: 0.3)
    {:ok, agent: agent}
  end

  describe "Customer support automation" do
    test "classify and route customer inquiry", %{agent: agent} do
      # Classifier agent
      classifier = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["Classify customer inquiries as: technical, billing, or general"]
          }
      }

      inquiry = %{chat_message: "I can't log into my account"}

      {_classifier, classification} = BaseAgent.run(classifier, inquiry)

      assert is_binary(classification.chat_message)
      # Should classify as technical issue
    end
  end

  describe "Content generation pipeline" do
    test "generate and refine content", %{agent: agent} do
      # Generator
      generator = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["Generate creative content based on the topic"]
          }
      }

      # Refiner
      refiner = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["Improve and polish the content"]
          }
      }

      topic = %{chat_message: "Write about the benefits of exercise"}

      {generator, draft} = BaseAgent.run(generator, topic)
      assert is_binary(draft.chat_message)

      {_refiner, final_content} = BaseAgent.run(refiner, draft)
      assert is_binary(final_content.chat_message)
    end
  end
end
