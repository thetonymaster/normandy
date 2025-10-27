defmodule Normandy.Integration.MultiAgentWorkflowsTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent

  alias Normandy.Coordination.{
    SequentialOrchestrator,
    ParallelOrchestrator,
    AgentProcess,
    AgentSupervisor
  }

  alias NormandyTest.Support.IntegrationHelper

  @moduletag :integration
  @moduletag :api
  @moduletag timeout: 120_000

  setup do
    # These tests require a real API key
    # Skip by running: mix test --exclude api
    agent = IntegrationHelper.create_real_agent(temperature: 0.3)
    {:ok, agent: agent}
  end

  describe "Sequential orchestration with real LLM" do
    test "agents execute in sequence", %{agent: agent} do
      agent1 = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["You are Agent 1. Add 5 to any number you receive."]
          }
      }

      agent2 = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["You are Agent 2. Multiply the number by 2."]
          }
      }

      agents = [agent1, agent2]
      input = %{chat_message: "Start with number 10"}

      {:ok, final_result} = SequentialOrchestrator.execute(agents, input)

      # Should have processed through both agents
      assert is_map(final_result)
      assert Map.has_key?(final_result, :chat_message)
    end
  end

  describe "Parallel orchestration with real LLM" do
    test "agents execute concurrently", %{agent: agent} do
      agent1 = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["You analyze sentiment"]
          }
      }

      agent2 = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["You count words"]
          }
      }

      agent3 = %{
        agent
        | prompt_specification: %{
            agent.prompt_specification
            | background: ["You extract key topics"]
          }
      }

      agents = [agent1, agent2, agent3]
      input = %{chat_message: "I love sunny days and ice cream"}

      {:ok, results} = ParallelOrchestrator.execute(agents, input)

      # Should have results from all agents
      assert is_list(results)
      assert length(results) == 3
      assert Enum.all?(results, fn r -> Map.has_key?(r, :chat_message) end)
    end
  end
end
