defmodule Normandy.Coordination.AgentProcessTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Test.StubClient

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
      # A unique name, so no other test can hold it.
      name = :"test_agent_#{System.unique_integer([:positive])}"

      assert {:ok, _pid} = AgentProcess.start_link(agent: agent, name: name)
      assert Process.whereis(name) != nil
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

  describe "inline failures" do
    defp raising_agent do
      BaseAgent.init(%{
        client: %Normandy.Test.StubClient{reply: fn _rm -> raise "client bug" end},
        model: "m"
      })
    end

    test "run/3 replies a Normandy failure as the bare exception", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      capture_log(fn ->
        assert {:error, %Normandy.Schema.ValidationError{}} =
                 AgentProcess.run(pid, %{custom: "data"})
      end)

      assert Process.alive?(pid)
    end

    test "run/3 replies a raised bug as the bare exception and logs arities only" do
      {:ok, pid} = AgentProcess.start_link(agent: raising_agent(), agent_id: "buggy")

      log =
        capture_log(fn ->
          assert {:error, %RuntimeError{message: "client bug"}} = AgentProcess.run(pid, "go")
        end)

      assert log =~ "Agent buggy raised RuntimeError"
      assert log =~ ~r/Normandy\.Agents\.BaseAgent\.\S+\/\d+/
      assert Process.alive?(pid)
    end

    test "cast/3 sends a Normandy failure as the bare exception", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent, agent_id: "async_invalid")

      capture_log(fn ->
        :ok = AgentProcess.cast(pid, %{custom: "data"}, reply_to: self())

        assert_receive {:agent_result, "async_invalid",
                        {:error, %Normandy.Schema.ValidationError{}}},
                       1000
      end)
    end

    test "cast/3 sends a raised bug as the bare exception and logs it" do
      {:ok, pid} = AgentProcess.start_link(agent: raising_agent(), agent_id: "async_buggy")

      log =
        capture_log(fn ->
          :ok = AgentProcess.cast(pid, "go", reply_to: self())

          assert_receive {:agent_result, "async_buggy",
                          {:error, %RuntimeError{message: "client bug"}}},
                         1000
        end)

      assert log =~ "Async agent async_buggy raised RuntimeError"
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

      # The casts run asynchronously; wait for both to be counted.
      assert wait_until(fn -> AgentProcess.get_stats(pid).run_count == 2 end)
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

  describe "update_agent/2 with a function that does not return an agent config" do
    test "raises in the caller and keeps the process and its agent", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      assert_raise ArgumentError,
                   "Normandy.Coordination.AgentProcess.update_agent/3: the function must " <>
                     "return a %Normandy.Agents.BaseAgentConfig{}, got: a map",
                   fn -> AgentProcess.update_agent(pid, fn a -> Map.from_struct(a) end) end

      # One name for both arities, the one option errors use (6.5c re-review).
      assert_raise ArgumentError,
                   ~r"^Normandy.Coordination.AgentProcess.update_agent/3: the",
                   fn ->
                     AgentProcess.update_agent(pid, fn a -> Map.from_struct(a) end,
                       timeout: 1_000
                     )
                   end

      assert Process.alive?(pid)
      assert AgentProcess.get_agent(pid) == agent
    end
  end

  describe "stop/1" do
    test "stops agent process gracefully", %{agent: agent} do
      {:ok, pid} = AgentProcess.start_link(agent: agent)

      assert Process.alive?(pid)
      # GenServer.stop/2 returns once the process has terminated.
      assert :ok = AgentProcess.stop(pid)
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

    # Every cast's LLM call is held until the test releases it, so the reads below
    # happen while a run is in flight and 19 more wait behind it (no wall-clock bound).
    test "async execution doesn't block GenServer" do
      {:ok, pid} = AgentProcess.start_link(agent: gated_agent(), agent_id: "nonblocking")

      for i <- 1..20 do
        AgentProcess.cast(pid, "Async #{i}", reply_to: self())
      end

      assert_receive {:llm_started, 1, worker}, 5_000

      # A blocking implementation exits each of these with {:timeout, _} after 5 s.
      stats = AgentProcess.get_stats(pid)
      assert stats.agent_id == "nonblocking"
      assert stats.run_count == 0
      assert :queue.len(:sys.get_state(pid).queue) == 19

      send(worker, {:release, 1})
      assert_receive {:agent_result, "nonblocking", {:ok, "answer 1"}}, 5_000

      for n <- 2..20 do
        assert_receive {:llm_started, ^n, worker}, 5_000
        send(worker, {:release, n})
        assert_receive {:agent_result, "nonblocking", {:ok, answer}}, 5_000
        assert answer == "answer #{n}"
      end

      assert AgentProcess.get_stats(pid).run_count == 20
    end

    # A client whose call `n` sends `{:llm_started, n, worker}` and blocks in the
    # worker until the test sends it `{:release, n}`.
    defp gated_agent do
      parent = self()
      calls = :atomics.new(1, [])

      reply = fn response_model ->
        n = :atomics.add_get(calls, 1, 1)
        send(parent, {:llm_started, n, self()})

        receive do
          {:release, ^n} -> %{response_model | chat_message: "answer #{n}"}
        end
      end

      BaseAgent.init(%{client: %StubClient{reply: reply}, model: "m"})
    end
  end
end
