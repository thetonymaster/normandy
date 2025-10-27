defmodule Normandy.Coordination.AgentPoolTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.AgentPool

  # Helper to create agent config
  defp create_agent_config do
    %{
      client: %NormandyTest.Support.ModelMockup{},
      model: "claude-3-5-sonnet-20241022",
      temperature: 0.7
    }
  end

  describe "start_link/1" do
    test "starts a pool with default options" do
      agent_config = create_agent_config()

      assert {:ok, pool} = AgentPool.start_link(agent_config: agent_config)
      assert Process.alive?(pool)

      AgentPool.stop(pool)
    end

    test "starts a named pool" do
      agent_config = create_agent_config()

      assert {:ok, _pool} =
               AgentPool.start_link(name: :test_pool, agent_config: agent_config)

      assert Process.whereis(:test_pool) != nil

      AgentPool.stop(:test_pool)
    end

    test "starts pool with custom size" do
      agent_config = create_agent_config()

      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 5)

      stats = AgentPool.stats(pool)
      assert stats.size == 5
      assert stats.available == 5

      AgentPool.stop(pool)
    end

    test "starts pool with custom overflow" do
      agent_config = create_agent_config()

      {:ok, pool} =
        AgentPool.start_link(agent_config: agent_config, size: 3, max_overflow: 10)

      stats = AgentPool.stats(pool)
      assert stats.max_overflow == 10

      AgentPool.stop(pool)
    end

    test "starts pool with FIFO strategy" do
      agent_config = create_agent_config()

      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, strategy: :fifo)

      # Pool starts successfully, strategy is internal
      assert Process.alive?(pool)

      AgentPool.stop(pool)
    end

    test "starts pool with LIFO strategy" do
      agent_config = create_agent_config()

      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, strategy: :lifo)

      assert Process.alive?(pool)

      AgentPool.stop(pool)
    end
  end

  describe "transaction/3" do
    test "executes function with agent from pool" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 3)

      result =
        AgentPool.transaction(pool, fn agent_pid ->
          assert is_pid(agent_pid)
          assert Process.alive?(agent_pid)
          :success
        end)

      assert {:ok, :success} = result

      AgentPool.stop(pool)
    end

    test "automatically checks in agent after transaction" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 3)

      # Initial state
      stats_before = AgentPool.stats(pool)
      assert stats_before.available == 3
      assert stats_before.in_use == 0

      # Execute transaction
      AgentPool.transaction(pool, fn _agent_pid ->
        # During transaction, one agent should be in use
        stats_during = AgentPool.stats(pool)
        assert stats_during.available == 2
        assert stats_during.in_use == 1

        :result
      end)

      # After transaction, agent should be returned
      stats_after = AgentPool.stats(pool)
      assert stats_after.available == 3
      assert stats_after.in_use == 0

      AgentPool.stop(pool)
    end

    test "checks in agent even if function raises" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 2)

      # This should raise but still check in the agent
      catch_error(
        AgentPool.transaction(pool, fn _agent_pid ->
          raise "test error"
        end)
      )

      # Agent should be returned to pool
      stats = AgentPool.stats(pool)
      assert stats.available == 2
      assert stats.in_use == 0

      AgentPool.stop(pool)
    end

    test "respects timeout option" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 2)

      # With available agents, timeout should not be an issue
      result =
        AgentPool.transaction(pool, [timeout: 1000], fn agent_pid ->
          assert is_pid(agent_pid)
          :success
        end)

      assert {:ok, :success} = result

      AgentPool.stop(pool)
    end

    test "handles multiple concurrent transactions" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 5)

      # Start 10 concurrent transactions
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            AgentPool.transaction(pool, fn _agent_pid ->
              Process.sleep(1)
              i
            end)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # All agents should be returned
      stats = AgentPool.stats(pool)
      assert stats.available == 5
      assert stats.in_use == 0

      AgentPool.stop(pool)
    end
  end

  describe "checkout/2 and checkin/2" do
    test "checks out agent from pool" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 3)

      assert {:ok, agent_pid} = AgentPool.checkout(pool)
      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)

      stats = AgentPool.stats(pool)
      assert stats.available == 2
      assert stats.in_use == 1

      AgentPool.checkin(pool, agent_pid)
      AgentPool.stop(pool)
    end

    test "checks in agent back to pool" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 3)

      {:ok, agent_pid} = AgentPool.checkout(pool)
      :ok = AgentPool.checkin(pool, agent_pid)

      stats = AgentPool.stats(pool)
      assert stats.available == 3
      assert stats.in_use == 0

      AgentPool.stop(pool)
    end

    test "can checkout multiple agents" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 5)

      {:ok, pid1} = AgentPool.checkout(pool)
      {:ok, pid2} = AgentPool.checkout(pool)
      {:ok, pid3} = AgentPool.checkout(pool)

      # All should be different
      assert pid1 != pid2
      assert pid2 != pid3
      assert pid1 != pid3

      stats = AgentPool.stats(pool)
      assert stats.available == 2
      assert stats.in_use == 3

      AgentPool.checkin(pool, pid1)
      AgentPool.checkin(pool, pid2)
      AgentPool.checkin(pool, pid3)
      AgentPool.stop(pool)
    end

    test "non-blocking checkout returns error when pool empty" do
      agent_config = create_agent_config()

      {:ok, pool} =
        AgentPool.start_link(agent_config: agent_config, size: 1, max_overflow: 0)

      # Checkout the only agent
      {:ok, _agent_pid} = AgentPool.checkout(pool)

      # Non-blocking checkout should fail
      assert {:error, :no_agents} = AgentPool.checkout(pool, block: false)

      AgentPool.stop(pool)
    end

    test "respects timeout on checkout" do
      agent_config = create_agent_config()

      {:ok, pool} =
        AgentPool.start_link(agent_config: agent_config, size: 1, max_overflow: 0)

      # Checkout the only agent
      {:ok, _agent_pid} = AgentPool.checkout(pool)

      # With short timeout, GenServer.call will exit with timeout
      catch_exit(AgentPool.checkout(pool, timeout: 50, block: true))

      AgentPool.stop(pool)
    end
  end

  describe "overflow handling" do
    test "creates overflow agents when pool exhausted" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 2, max_overflow: 3)

      # Checkout all regular agents
      {:ok, _pid1} = AgentPool.checkout(pool)
      {:ok, _pid2} = AgentPool.checkout(pool)

      stats = AgentPool.stats(pool)
      assert stats.available == 0
      assert stats.in_use == 2
      assert stats.overflow == 0

      # Checkout overflow agent
      {:ok, _pid3} = AgentPool.checkout(pool)

      stats = AgentPool.stats(pool)
      assert stats.available == 0
      assert stats.in_use == 3
      assert stats.overflow == 1

      AgentPool.stop(pool)
    end

    test "terminates overflow agents on checkin" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 2, max_overflow: 2)

      # Checkout all agents plus overflow
      {:ok, pid1} = AgentPool.checkout(pool)
      {:ok, pid2} = AgentPool.checkout(pool)
      {:ok, overflow_pid} = AgentPool.checkout(pool)

      stats = AgentPool.stats(pool)
      assert stats.overflow == 1

      # Checkin regular agents first
      AgentPool.checkin(pool, pid1)
      AgentPool.checkin(pool, pid2)

      # Now checkin overflow agent - should be terminated
      AgentPool.checkin(pool, overflow_pid)

      # Give it time to process
      Process.sleep(50)

      stats = AgentPool.stats(pool)
      assert stats.overflow == 0
      assert stats.available == 2
      assert stats.in_use == 0

      AgentPool.stop(pool)
    end

    test "returns error when max overflow reached" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 1, max_overflow: 1)

      # Checkout all agents
      {:ok, _pid1} = AgentPool.checkout(pool)
      {:ok, _pid2} = AgentPool.checkout(pool)

      # Should fail with non-blocking
      assert {:error, :no_agents} = AgentPool.checkout(pool, block: false)

      AgentPool.stop(pool)
    end
  end

  describe "stats/1" do
    test "returns initial pool statistics" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 5, max_overflow: 3)

      stats = AgentPool.stats(pool)

      assert stats.size == 5
      assert stats.available == 5
      assert stats.in_use == 0
      assert stats.overflow == 0
      assert stats.max_overflow == 3
      assert stats.waiting == 0

      AgentPool.stop(pool)
    end

    test "tracks agents in use" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 3)

      {:ok, _pid1} = AgentPool.checkout(pool)
      {:ok, _pid2} = AgentPool.checkout(pool)

      stats = AgentPool.stats(pool)
      assert stats.available == 1
      assert stats.in_use == 2

      AgentPool.stop(pool)
    end

    test "tracks waiting checkouts" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 1, max_overflow: 0)

      # Checkout the only agent
      {:ok, _pid} = AgentPool.checkout(pool)

      # Start a task that will wait
      task =
        Task.async(fn ->
          AgentPool.checkout(pool, timeout: 5000)
        end)

      # Give it time to start waiting
      Process.sleep(10)

      stats = AgentPool.stats(pool)
      assert stats.waiting == 1

      # Cleanup
      Task.shutdown(task, :brutal_kill)
      AgentPool.stop(pool)
    end
  end

  describe "fault tolerance" do
    test "handles agent process death" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 3)

      {:ok, agent_pid} = AgentPool.checkout(pool)

      # Kill the agent
      Process.exit(agent_pid, :kill)
      Process.sleep(50)

      # Pool should recover by creating a new agent
      stats = AgentPool.stats(pool)
      # Depending on timing, might be 2 or 3 available
      # The important thing is total capacity is maintained
      total = stats.available + stats.in_use
      assert total == 3

      AgentPool.stop(pool)
    end

    test "replaces dead agent with new one" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 2)

      {:ok, agent_pid} = AgentPool.checkout(pool)
      original_count = 2

      # Kill the agent
      Process.exit(agent_pid, :kill)
      Process.sleep(50)

      # Should still have capacity for 2 agents
      stats = AgentPool.stats(pool)
      total = stats.available + stats.in_use
      assert total == original_count

      AgentPool.stop(pool)
    end
  end

  describe "waiting queue" do
    test "serves waiting checkouts when agent available" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 1, max_overflow: 0)

      # Checkout the only agent
      {:ok, pid1} = AgentPool.checkout(pool)

      # Start a task that will wait
      task =
        Task.async(fn ->
          AgentPool.checkout(pool, timeout: 1000)
        end)

      # Give it time to start waiting
      Process.sleep(10)

      # Return the agent - should go to waiting task
      AgentPool.checkin(pool, pid1)

      # Task should receive the agent
      assert {:ok, agent_pid} = Task.await(task, 1000)
      assert is_pid(agent_pid)

      AgentPool.checkin(pool, agent_pid)
      AgentPool.stop(pool)
    end

    test "processes waiting queue in order" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 1, max_overflow: 0)

      # Checkout the only agent
      {:ok, pid} = AgentPool.checkout(pool)

      # Start multiple waiting tasks
      parent = self()

      task1 =
        Task.async(fn ->
          result = AgentPool.checkout(pool, timeout: 2000)
          send(parent, {:task1, result})
          result
        end)

      Process.sleep(5)

      task2 =
        Task.async(fn ->
          result = AgentPool.checkout(pool, timeout: 2000)
          send(parent, {:task2, result})
          result
        end)

      Process.sleep(10)

      # Return agent - should go to first waiting task
      AgentPool.checkin(pool, pid)

      # First task should get it
      assert_receive {:task1, {:ok, _pid1}}, 500

      # Get the agent from task1 result
      {:ok, pid1} = Task.await(task1, 100)

      # Return it for task2
      AgentPool.checkin(pool, pid1)

      assert_receive {:task2, {:ok, _pid2}}, 500

      {:ok, pid2} = Task.await(task2, 100)
      AgentPool.checkin(pool, pid2)

      AgentPool.stop(pool)
    end
  end

  describe "stop/1" do
    test "stops pool gracefully" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config)

      assert Process.alive?(pool)
      assert :ok = AgentPool.stop(pool)

      Process.sleep(10)
      refute Process.alive?(pool)
    end

    test "terminates all agents on stop" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 3)

      # Checkout an agent to get its PID
      {:ok, agent_pid} = AgentPool.checkout(pool)

      # Stop pool
      AgentPool.stop(pool)

      Process.sleep(50)

      # Pool should be dead
      refute Process.alive?(pool)
    end
  end

  describe "concurrent operations" do
    test "handles high concurrent checkout/checkin load" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 10, max_overflow: 5)

      # Start many concurrent transactions
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            AgentPool.transaction(pool, fn _agent_pid ->
              Process.sleep(1)
              i
            end)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      assert Enum.all?(results, fn {:ok, _} -> true end)

      # Pool should be stable
      stats = AgentPool.stats(pool)
      assert stats.available == 10
      assert stats.in_use == 0
      assert stats.overflow == 0

      AgentPool.stop(pool)
    end

    test "maintains pool integrity under stress" do
      agent_config = create_agent_config()
      {:ok, pool} = AgentPool.start_link(agent_config: agent_config, size: 5)

      # Mix of checkout, checkin, and transaction operations
      tasks =
        for i <- 1..30 do
          Task.async(fn ->
            case rem(i, 3) do
              0 ->
                # Transaction
                AgentPool.transaction(pool, fn _pid -> :ok end)

              1 ->
                # Manual checkout/checkin
                {:ok, pid} = AgentPool.checkout(pool)
                Process.sleep(1)
                AgentPool.checkin(pool, pid)
                {:ok, :done}

              2 ->
                # Just get stats
                AgentPool.stats(pool)
                {:ok, :stats}
            end
          end)
        end

      _results = Task.await_many(tasks, 10_000)

      # Pool should be consistent
      stats = AgentPool.stats(pool)
      assert stats.available == 5
      assert stats.in_use == 0

      AgentPool.stop(pool)
    end
  end
end
