defmodule Normandy.Integration.MultiAgentTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{SequentialOrchestrator, ParallelOrchestrator}
  alias NormandyTest.Support.NormandyIntegrationHelper

  @moduletag :normandy_integration
  @moduletag :api
  @moduletag timeout: 120_000

  # ExUnit setup cannot skip at runtime (returning {:skip, _} raises), so gate the
  # whole module at compile time: skipped when no API key is present (shown as
  # skipped, not failed), run when one is.
  unless NormandyIntegrationHelper.api_key_available?() do
    @moduletag skip:
                 "API key not available. Set API_KEY or ANTHROPIC_API_KEY environment variable."
  end

  setup do
    agent = NormandyIntegrationHelper.create_real_agent(temperature: 0.3)
    {:ok, agent: agent}
  end

  describe "Sequential orchestration" do
    test "two agents process in sequence", %{agent: agent} do
      agent1 = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["You extract numbers from text. Output just the number."]
          }
      }

      agent2 = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["You double the number you receive. Output just the result."]
          }
      }

      agents = [agent1, agent2]
      input = %{chat_message: "The answer is 21"}

      {:ok, final_result} = SequentialOrchestrator.execute(agents, input)

      assert is_map(final_result)
      assert Map.has_key?(final_result, :chat_message)
      assert is_binary(final_result.chat_message)
    end
  end

  describe "Parallel orchestration" do
    test "multiple agents process concurrently", %{agent: agent} do
      agent1 = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["Count the words"]
          }
      }

      agent2 = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["Count the letters"]
          }
      }

      agents = [agent1, agent2]
      input = %{chat_message: "Hello world"}

      {:ok, results} = ParallelOrchestrator.execute(agents, input)

      assert is_list(results)
      assert length(results) == 2
      assert Enum.all?(results, fn r -> Map.has_key?(r, :chat_message) end)
    end
  end
end
