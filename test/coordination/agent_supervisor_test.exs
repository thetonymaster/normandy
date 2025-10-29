defmodule Normandy.Coordination.AgentSupervisorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{AgentProcess, AgentSupervisor}

  setup do
    config = %{
      client: %NormandyTest.Support.ModelMockup{},
      model: "claude-haiku-4-5-20251001",
      temperature: 0.7
    }

    agent = BaseAgent.init(config)
    %{agent: agent}
  end

  describe "start_link/1" do
    test "starts supervisor" do
      assert {:ok, pid} = AgentSupervisor.start_link()
      assert Process.alive?(pid)
    end

    test "starts named supervisor" do
      assert {:ok, _pid} = AgentSupervisor.start_link(name: :test_supervisor)
      assert Process.whereis(:test_supervisor) != nil
    end

    test "accepts supervision options" do
      assert {:ok, pid} =
               AgentSupervisor.start_link(
                 max_restarts: 5,
                 max_seconds: 10
               )

      assert Process.alive?(pid)
    end
  end

  describe "start_agent/2" do
    test "starts agent under supervision", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      assert {:ok, agent_pid} = AgentSupervisor.start_agent(sup, agent: agent)
      assert Process.alive?(agent_pid)
    end

    test "starts agent with custom agent_id", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      {:ok, pid} =
        AgentSupervisor.start_agent(sup,
          agent: agent,
          agent_id: "custom_agent"
        )

      assert AgentProcess.get_id(pid) == "custom_agent"
    end

    test "starts multiple agents", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      {:ok, pid1} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_1")
      {:ok, pid2} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_2")

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end

    test "supports different restart strategies", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      # Permanent - always restart
      {:ok, _pid1} =
        AgentSupervisor.start_agent(sup,
          agent: agent,
          restart: :permanent
        )

      # Temporary - never restart
      {:ok, _pid2} =
        AgentSupervisor.start_agent(sup,
          agent: agent,
          restart: :temporary
        )

      # Transient - restart only on abnormal exit (default)
      {:ok, _pid3} =
        AgentSupervisor.start_agent(sup,
          agent: agent,
          restart: :transient
        )

      assert AgentSupervisor.count_agents(sup) == 3
    end
  end

  describe "terminate_agent/2" do
    test "terminates supervised agent", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()
      {:ok, agent_pid} = AgentSupervisor.start_agent(sup, agent: agent)

      assert Process.alive?(agent_pid)
      assert :ok = AgentSupervisor.terminate_agent(sup, agent_pid)

      Process.sleep(10)
      refute Process.alive?(agent_pid)
    end

    test "returns error for non-existent agent", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()
      fake_pid = spawn(fn -> :ok end)

      assert {:error, :not_found} = AgentSupervisor.terminate_agent(sup, fake_pid)
    end
  end

  describe "list_agents/1" do
    test "returns empty list for no agents" do
      {:ok, sup} = AgentSupervisor.start_link()
      assert AgentSupervisor.list_agents(sup) == []
    end

    test "lists all supervised agents", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      {:ok, _pid1} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_1")
      {:ok, _pid2} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_2")
      {:ok, _pid3} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_3")

      agents = AgentSupervisor.list_agents(sup)
      assert length(agents) == 3

      agent_ids = Enum.map(agents, fn {_pid, id} -> id end)
      assert "agent_1" in agent_ids
      assert "agent_2" in agent_ids
      assert "agent_3" in agent_ids
    end

    test "returns pid and agent_id tuples", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()
      {:ok, pid} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "test_agent")

      agents = AgentSupervisor.list_agents(sup)
      assert [{^pid, "test_agent"}] = agents
    end
  end

  describe "count_agents/1" do
    test "returns zero for no agents" do
      {:ok, sup} = AgentSupervisor.start_link()
      assert AgentSupervisor.count_agents(sup) == 0
    end

    test "returns count of supervised agents", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      AgentSupervisor.start_agent(sup, agent: agent)
      AgentSupervisor.start_agent(sup, agent: agent)
      AgentSupervisor.start_agent(sup, agent: agent)

      assert AgentSupervisor.count_agents(sup) == 3
    end
  end

  describe "find_agent/2" do
    test "finds agent by agent_id", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()
      {:ok, pid} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "findable")

      assert {:ok, ^pid} = AgentSupervisor.find_agent(sup, "findable")
    end

    test "returns error for non-existent agent_id", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()
      AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_1")

      assert {:error, :not_found} = AgentSupervisor.find_agent(sup, "nonexistent")
    end

    test "finds correct agent among multiple", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_1")
      {:ok, target_pid} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_2")
      AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_3")

      assert {:ok, ^target_pid} = AgentSupervisor.find_agent(sup, "agent_2")
    end
  end

  describe "terminate_all/1" do
    test "terminates all supervised agents", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      {:ok, pid1} = AgentSupervisor.start_agent(sup, agent: agent)
      {:ok, pid2} = AgentSupervisor.start_agent(sup, agent: agent)
      {:ok, pid3} = AgentSupervisor.start_agent(sup, agent: agent)

      assert :ok = AgentSupervisor.terminate_all(sup)

      Process.sleep(20)

      refute Process.alive?(pid1)
      refute Process.alive?(pid2)
      refute Process.alive?(pid3)
      assert AgentSupervisor.count_agents(sup) == 0
    end

    test "handles empty supervisor" do
      {:ok, sup} = AgentSupervisor.start_link()
      assert :ok = AgentSupervisor.terminate_all(sup)
      assert AgentSupervisor.count_agents(sup) == 0
    end
  end

  describe "fault tolerance" do
    test "restarts transient agents on abnormal exit", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      {:ok, pid} =
        AgentSupervisor.start_agent(sup,
          agent: agent,
          agent_id: "restartable",
          restart: :transient
        )

      # Kill the process abnormally
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Should have been restarted
      {:ok, new_pid} = AgentSupervisor.find_agent(sup, "restartable")
      assert new_pid != pid
      assert Process.alive?(new_pid)
    end

    test "does not restart temporary agents", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      {:ok, pid} =
        AgentSupervisor.start_agent(sup,
          agent: agent,
          agent_id: "temporary",
          restart: :temporary
        )

      # Kill the process
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Should NOT have been restarted
      assert {:error, :not_found} = AgentSupervisor.find_agent(sup, "temporary")
    end

    test "restarts permanent agents even on normal exit", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      {:ok, pid} =
        AgentSupervisor.start_agent(sup,
          agent: agent,
          agent_id: "permanent",
          restart: :permanent
        )

      # Stop normally
      AgentProcess.stop(pid)
      Process.sleep(50)

      # Should have been restarted
      {:ok, new_pid} = AgentSupervisor.find_agent(sup, "permanent")
      assert new_pid != pid
      assert Process.alive?(new_pid)
    end
  end

  describe "integration with AgentProcess" do
    test "supervised agents can execute work", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      {:ok, pid} =
        AgentSupervisor.start_agent(sup,
          agent: agent,
          agent_id: "worker"
        )

      # Agent should work normally
      assert {:ok, result} = AgentProcess.run(pid, "Test input")
      assert is_map(result)
    end

    test "supervised agents maintain state across runs", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      {:ok, pid} =
        AgentSupervisor.start_agent(sup,
          agent: agent,
          agent_id: "stateful"
        )

      AgentProcess.run(pid, "First run")
      AgentProcess.run(pid, "Second run")

      stats = AgentProcess.get_stats(pid)
      assert stats.run_count == 2
    end
  end

  describe "dynamic agent management" do
    test "supports adding agents dynamically", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      # Start with 2 agents
      AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_1")
      AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_2")
      assert AgentSupervisor.count_agents(sup) == 2

      # Add more dynamically
      AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_3")
      AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_4")
      assert AgentSupervisor.count_agents(sup) == 4
    end

    test "supports removing agents dynamically", %{agent: agent} do
      {:ok, sup} = AgentSupervisor.start_link()

      {:ok, pid1} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_1")
      {:ok, pid2} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_2")
      {:ok, pid3} = AgentSupervisor.start_agent(sup, agent: agent, agent_id: "agent_3")

      assert AgentSupervisor.count_agents(sup) == 3

      # Remove one
      AgentSupervisor.terminate_agent(sup, pid2)
      Process.sleep(10)

      assert AgentSupervisor.count_agents(sup) == 2
      assert {:error, :not_found} = AgentSupervisor.find_agent(sup, "agent_2")
      assert {:ok, ^pid1} = AgentSupervisor.find_agent(sup, "agent_1")
      assert {:ok, ^pid3} = AgentSupervisor.find_agent(sup, "agent_3")
    end
  end
end
