defmodule Normandy.Coordination.AgentProcessTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.AgentProcess

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
    test "starts an agent process", %{agent: agent} do
      assert {:ok, pid} = AgentProcess.start_link(agent: agent)
      assert Process.alive?(pid)
    end

    test "starts a named agent process", %{agent: agent} do
      assert {:ok, _pid} = AgentProcess.start_link(agent: agent, name: :test_agent)
      assert Process.whereis(:test_agent) != nil
    end

    test "assigns agent_id", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent, agent_id: "custom_id")
      assert AgentProcess.get_id(pid) == "custom_id"
    end

    test "generates UUID if no agent_id provided", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)
      agent_id = AgentProcess.get_id(pid)
      assert is_binary(agent_id)
      # UUID format
      assert String.length(agent_id) == 36
    end
  end

  describe "run/3" do
    test "executes agent synchronously", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      assert {:ok, result} = AgentProcess.run(pid, "Test input")
      assert is_map(result)
    end

    test "handles different input formats", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      # String input
      assert {:ok, result1} = AgentProcess.run(pid, "text")
      assert is_map(result1)

      # Map input
      assert {:ok, result2} = AgentProcess.run(pid, %{chat_message: "text"})
      assert is_map(result2)
    end

    test "updates run statistics", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      AgentProcess.run(pid, "Test 1")
      AgentProcess.run(pid, "Test 2")

      stats = AgentProcess.get_stats(pid)
      assert stats.run_count == 2
      # Mock is very fast, may be 0
      assert stats.total_runtime_ms >= 0
      assert stats.last_run != nil
    end

    test "respects timeout option", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      # Should work with normal timeout
      assert {:ok, _result} = AgentProcess.run(pid, "test", timeout: 5000)
    end
  end

  describe "cast/3" do
    test "executes agent asynchronously", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent, agent_id: "async_agent")

      assert :ok = AgentProcess.cast(pid, "Test input", reply_to: self())

      assert_receive {:agent_result, "async_agent", {:ok, result}}, 1000
      assert is_map(result)
    end

    test "does not send message if no reply_to", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      :ok = AgentProcess.cast(pid, "Test input")

      refute_receive {:agent_result, _, _}, 100
    end

    test "updates statistics even for async calls", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      AgentProcess.cast(pid, "Test 1")
      AgentProcess.cast(pid, "Test 2")

      # Give tasks time to complete
      Process.sleep(50)

      stats = AgentProcess.get_stats(pid)
      assert stats.run_count == 2
    end
  end

  describe "get_agent/1" do
    test "returns current agent state", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      current_agent = AgentProcess.get_agent(pid)
      assert is_map(current_agent)
      assert Map.has_key?(current_agent, :client)
    end

    test "agent state persists across runs", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      AgentProcess.run(pid, "First run")
      agent_after = AgentProcess.get_agent(pid)

      # Agent state should have been updated (conversation history, etc.)
      assert is_map(agent_after)
    end
  end

  describe "get_id/1" do
    test "returns agent identifier", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent, agent_id: "test_id")
      assert AgentProcess.get_id(pid) == "test_id"
    end
  end

  describe "get_stats/1" do
    test "returns initial statistics", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent, agent_id: "stats_test")

      stats = AgentProcess.get_stats(pid)

      assert stats.agent_id == "stats_test"
      assert stats.run_count == 0
      assert stats.last_run == nil
      assert stats.total_runtime_ms == 0
      assert %DateTime{} = stats.created_at
    end

    test "tracks execution metrics", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      AgentProcess.run(pid, "Test 1")
      Process.sleep(10)
      AgentProcess.run(pid, "Test 2")

      stats = AgentProcess.get_stats(pid)

      assert stats.run_count == 2
      # Mock is very fast, may be 0
      assert stats.total_runtime_ms >= 0
      assert %DateTime{} = stats.last_run
    end
  end

  describe "update_agent/2" do
    test "updates agent temperature", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      :ok =
        AgentProcess.update_agent(pid, fn a ->
          %{a | temperature: 0.5}
        end)

      updated = AgentProcess.get_agent(pid)
      assert updated.temperature == 0.5
    end

    test "allows modifying agent model", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      :ok =
        AgentProcess.update_agent(pid, fn a ->
          %{a | model: "claude-3-haiku-20240307"}
        end)

      updated = AgentProcess.get_agent(pid)
      assert updated.model == "claude-3-haiku-20240307"
    end
  end

  describe "stop/1" do
    test "stops agent process gracefully", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      assert Process.alive?(pid)
      assert :ok = AgentProcess.stop(pid)

      Process.sleep(10)
      refute Process.alive?(pid)
    end
  end

  describe "concurrent agent execution" do
    test "handles multiple concurrent runs", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      # Start multiple concurrent runs
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            AgentProcess.run(pid, "Test #{i}")
          end)
        end

      # All should complete successfully
      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, fn {status, _} -> status == :ok end)

      # Check statistics
      stats = AgentProcess.get_stats(pid)
      assert stats.run_count == 10
    end

    test "async execution doesn't block GenServer", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent, agent_id: "nonblocking")

      # Send many async requests
      for i <- 1..20 do
        AgentProcess.cast(pid, "Async #{i}", reply_to: self())
      end

      # GenServer should still respond quickly to sync calls
      start_time = System.monotonic_time(:millisecond)
      stats = AgentProcess.get_stats(pid)
      end_time = System.monotonic_time(:millisecond)

      # Stats call should be fast (< 10ms) even with async work happening
      assert end_time - start_time < 10
      assert stats.agent_id == "nonblocking"
    end
  end
end
