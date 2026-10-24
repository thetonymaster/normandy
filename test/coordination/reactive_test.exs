defmodule Normandy.Coordination.ReactiveTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{AgentProcess, Reactive}
  alias Normandy.TurnError

  # Helper to create a test agent
  defp create_test_agent do
    config = %{
      client: %NormandyTest.Support.ModelMockup{},
      model: "claude-haiku-4-5-20251001",
      temperature: 0.7
    }

    BaseAgent.init(config)
  end

  # Helper to create an agent process
  defp create_agent_process do
    agent = create_test_agent()
    {:ok, pid} = AgentProcess.start_link(agent: agent)
    pid
  end

  # An agent whose model call exits (as a timed-out GenServer.call does) instead of raising.
  defp exiting_agent do
    BaseAgent.init(%{
      client: %Normandy.Test.StubClient{reply: fn _ -> exit(:boom) end},
      model: "exiting-model"
    })
  end

  defp throwing_agent do
    BaseAgent.init(%{
      client: %Normandy.Test.StubClient{reply: fn _ -> throw(:oops) end},
      model: "throwing-model"
    })
  end

  # An agent whose model call links a process that then crashes: the signal kills the
  # agent's task, and would kill a caller the task is linked to.
  defp linked_crash_agent do
    BaseAgent.init(%{
      client: %Normandy.Test.StubClient{
        reply: fn _ ->
          spawn_link(fn -> exit(:linked_boom) end)
          Process.sleep(500)
        end
      },
      model: "linked-crash-model"
    })
  end

  defp failing_agent(:exits), do: exiting_agent()
  defp failing_agent(:throws), do: throwing_agent()
  defp failing_agent(:linked_crash), do: linked_crash_agent()

  defp bad_callback(:raise), do: fn _id, _result -> raise "callback boom" end
  defp bad_callback(:throw), do: fn _id, _result -> throw(:callback) end

  # Runs `fun` in its own process so a caller killed by a linked task fails the
  # assertion instead of the test process.
  defp run_caller(fun) do
    {pid, mref} = spawn_monitor(fn -> exit({:returned, fun.()}) end)

    receive do
      {:DOWN, ^mref, :process, ^pid, {:returned, value}} -> {:returned, value}
      {:DOWN, ^mref, :process, ^pid, reason} -> {:caller_died, reason}
    after
      5_000 -> :caller_hung
    end
  end

  describe "agent failures never take down the caller" do
    for kind <- [:exits, :throws, :linked_crash] do
      test "race/3 with an agent that #{kind}" do
        assert {:returned, {:error, :all_failed}} =
                 run_caller(fn -> Reactive.race([failing_agent(unquote(kind))], "x") end)
      end

      test "some/3 with an agent that #{kind}" do
        assert {:returned, {:error, :insufficient_successes}} =
                 run_caller(fn ->
                   Reactive.some([failing_agent(unquote(kind))], "x", count: 1)
                 end)
      end

      test "all/3 with an agent that #{kind}" do
        assert {:returned, {:ok, %{"agent_0" => {:error, %TurnError{type: :task_down}}}}} =
                 run_caller(fn -> Reactive.all([failing_agent(unquote(kind))], "x") end)
      end

      test "all/3 fail_fast with an agent that #{kind}" do
        assert {:returned, {:error, %TurnError{type: :task_down}}} =
                 run_caller(fn ->
                   Reactive.all([failing_agent(unquote(kind))], "x", fail_fast: true)
                 end)
      end
    end

    for raiser <- [:raise, :throw] do
      test "race/3 with an on_complete that #{raiser}s" do
        assert {:returned, {:error, :all_failed}} =
                 run_caller(fn ->
                   Reactive.race([create_test_agent()], "x",
                     on_complete: bad_callback(unquote(raiser))
                   )
                 end)
      end

      test "some/3 with an on_complete that #{raiser}s" do
        assert {:returned, {:error, :insufficient_successes}} =
                 run_caller(fn ->
                   Reactive.some([create_test_agent()], "x",
                     count: 1,
                     on_complete: bad_callback(unquote(raiser))
                   )
                 end)
      end

      test "all/3 with an on_complete that #{raiser}s" do
        assert {:returned, {:ok, %{"agent_0" => {:error, error}}}} =
                 run_caller(fn ->
                   Reactive.all([create_test_agent()], "x",
                     on_complete: bad_callback(unquote(raiser))
                   )
                 end)

        assert is_exception(error)
      end
    end
  end

  describe "a caller that traps exits" do
    # Several agents finish before the outcome is decided, so race/3 and some/3 used to
    # leave their reports behind; every call left the per-call supervisor's {:EXIT, _, _}.
    setup do
      Process.flag(:trap_exit, true)
      agents = for _ <- 1..5, do: create_test_agent()
      {:ok, agents: agents}
    end

    test "finds its mailbox empty after race/3", %{agents: agents} do
      for _ <- 1..5, do: assert({:ok, _} = Reactive.race(agents, "go"))
      assert Process.info(self(), :messages) == {:messages, []}
    end

    test "finds its mailbox empty after all/3", %{agents: agents} do
      assert {:ok, _} = Reactive.all(agents, "go")
      assert Process.info(self(), :messages) == {:messages, []}
    end

    test "finds its mailbox empty after some/3", %{agents: agents} do
      for _ <- 1..5, do: assert({:ok, _} = Reactive.some(agents, "go", count: 2))
      assert Process.info(self(), :messages) == {:messages, []}
    end
  end

  describe "all/3 with no agents" do
    test "returns an empty result" do
      assert {:ok, %{}} = Reactive.all([], "go")
    end
  end

  describe "race/3" do
    test "an agent that exits is a failure, not an exit of the caller" do
      test_pid = self()

      assert {:error, :all_failed} =
               Reactive.race([exiting_agent()], "x",
                 on_complete: fn id, result -> send(test_pid, {:done, id, result}) end
               )

      assert_receive {:done, "agent_0", {:error, %TurnError{type: :task_down, reason: :boom}}}
    end

    test "timeout: :infinity waits for the first success" do
      assert {:ok, result} = Reactive.race([create_test_agent()], "test", timeout: :infinity)
      assert is_map(result)
    end

    test "returns first successful result from agents" do
      agents = [create_test_agent(), create_test_agent(), create_test_agent()]

      assert {:ok, result} = Reactive.race(agents, "test")
      assert is_map(result)
    end

    test "returns first successful result from agent processes" do
      pids = [create_agent_process(), create_agent_process(), create_agent_process()]

      # An agent process returns a chat answer as its text.
      assert {:ok, "stub answer"} = Reactive.race(pids, "test")

      # Cleanup
      Enum.each(pids, &AgentProcess.stop/1)
    end

    test "handles string input" do
      agents = [create_test_agent(), create_test_agent()]

      assert {:ok, result} = Reactive.race(agents, "test string")
      assert is_map(result)
    end

    test "handles map input" do
      agents = [create_test_agent(), create_test_agent()]

      assert {:ok, result} = Reactive.race(agents, %{chat_message: "test"})
      assert is_map(result)
    end

    test "calls on_complete callback for each agent" do
      agents = [create_test_agent(), create_test_agent()]
      parent = self()

      Reactive.race(agents, "test",
        on_complete: fn agent_id, result ->
          send(parent, {:completed, agent_id, result})
        end
      )

      # Should receive at least one callback
      assert_receive {:completed, _agent_id, _result}, 1000
    end

    test "works with single agent" do
      agent = create_test_agent()

      assert {:ok, result} = Reactive.race([agent], "test")
      assert is_map(result)
    end

    test "respects timeout parameter" do
      agents = [create_test_agent(), create_test_agent()]

      # With fast mock agents, this will succeed
      assert {:ok, _result} = Reactive.race(agents, "test", timeout: 5000)
    end
  end

  describe "all/3" do
    # An agent whose LLM call never returns, so it always runs past the timeout.
    defp stuck_agent do
      BaseAgent.init(%{
        client: %Normandy.Test.StubClient{reply: fn _ -> receive do: (:never -> :ok) end},
        model: "stuck-model"
      })
    end

    test "keeps the other results when an agent times out" do
      assert {:ok, results} =
               Reactive.all([create_test_agent(), stuck_agent(), create_test_agent()], "test",
                 timeout: 1_000
               )

      assert %{
               "agent_0" => {:ok, _},
               "agent_1" => {:error, %TurnError{type: :task_down, reason: :timeout}},
               "agent_2" => {:ok, _}
             } = results
    end

    test "an agent that exits is reported as a :task_down TurnError" do
      assert {:ok, %{"agent_0" => {:error, %TurnError{type: :task_down, reason: :boom}}}} =
               Reactive.all([exiting_agent()], "x")
    end

    test "fail_fast still stops on an agent that times out" do
      assert {:error, %TurnError{type: :task_down, reason: :timeout}} =
               Reactive.all([stuck_agent(), create_test_agent()], "test",
                 timeout: 100,
                 fail_fast: true
               )
    end

    test "waits for all agents to complete" do
      agents = [create_test_agent(), create_test_agent(), create_test_agent()]

      assert {:ok, results} = Reactive.all(agents, "test")

      # Should have results from all 3 agents
      assert map_size(results) == 3
      assert Map.has_key?(results, "agent_0")
      assert Map.has_key?(results, "agent_1")
      assert Map.has_key?(results, "agent_2")

      # All results should be successful
      Enum.each(results, fn {_id, result} ->
        assert {:ok, response} = result
        assert is_map(response)
      end)
    end

    test "works with agent processes" do
      pids = [create_agent_process(), create_agent_process(), create_agent_process()]

      assert {:ok, results} = Reactive.all(pids, "test")
      assert map_size(results) == 3

      # Cleanup
      Enum.each(pids, &AgentProcess.stop/1)
    end

    test "respects max_concurrency option" do
      agents = [
        create_test_agent(),
        create_test_agent(),
        create_test_agent(),
        create_test_agent()
      ]

      # Should work with concurrency limit
      assert {:ok, results} = Reactive.all(agents, "test", max_concurrency: 2)
      assert map_size(results) == 4
    end

    test "calls on_complete callback for each agent" do
      agents = [create_test_agent(), create_test_agent()]
      parent = self()

      Reactive.all(agents, "test",
        on_complete: fn agent_id, result ->
          send(parent, {:completed, agent_id, result})
        end
      )

      # Should receive callbacks for both agents
      assert_receive {:completed, "agent_0", _}, 1000
      assert_receive {:completed, "agent_1", _}, 1000
    end

    test "works with empty agent list when max_concurrency is set" do
      # Need to explicitly set max_concurrency to avoid Task.async_stream error
      assert {:ok, results} = Reactive.all([], "test", max_concurrency: 1)
      assert results == %{}
    end

    test "works with single agent" do
      assert {:ok, results} = Reactive.all([create_test_agent()], "test")
      assert map_size(results) == 1
    end

    test "fail_fast option works with successful agents" do
      agents = [create_test_agent(), create_test_agent()]

      assert {:ok, results} = Reactive.all(agents, "test", fail_fast: true)
      assert map_size(results) == 2
    end
  end

  describe "some/4" do
    test "waits for N successful results" do
      agents = [
        create_test_agent(),
        create_test_agent(),
        create_test_agent(),
        create_test_agent()
      ]

      # Wait for 2 out of 4 agents
      assert {:ok, results} = Reactive.some(agents, "test", count: 2)

      # Should have exactly 2 results
      assert map_size(results) == 2
    end

    test "works with agent processes" do
      pids = [create_agent_process(), create_agent_process(), create_agent_process()]

      assert {:ok, results} = Reactive.some(pids, "test", count: 2)
      assert map_size(results) == 2

      # Cleanup
      Enum.each(pids, &AgentProcess.stop/1)
    end

    test "waits for all agents if count equals agent count" do
      agents = [create_test_agent(), create_test_agent(), create_test_agent()]

      assert {:ok, results} = Reactive.some(agents, "test", count: 3)
      assert map_size(results) == 3
    end

    test "a count above the number of agents raises before any agent runs" do
      agents = [create_test_agent(), create_test_agent()]

      assert_raise ArgumentError,
                   "Normandy.Coordination.Reactive.some/3: :count must be at most the " <>
                     "number of agents (2), got: 5",
                   fn -> Reactive.some(agents, "test", count: 5) end
    end

    test "timeout: :infinity waits for the successes" do
      agents = [create_test_agent(), create_test_agent()]

      assert {:ok, results} = Reactive.some(agents, "test", count: 2, timeout: :infinity)
      assert map_size(results) == 2
    end

    test "an agent that exits does not kill the caller" do
      agents = [exiting_agent(), create_test_agent()]

      assert {:ok, results} = Reactive.some(agents, "test", count: 1)
      assert [{"agent_1", _}] = Map.to_list(results)
    end

    test "calls on_complete callback" do
      agents = [create_test_agent(), create_test_agent(), create_test_agent()]
      parent = self()

      Reactive.some(agents, "test",
        count: 2,
        on_complete: fn agent_id, result ->
          send(parent, {:completed, agent_id, result})
        end
      )

      # Should receive at least 2 callbacks
      assert_receive {:completed, _agent_id, _result}, 1000
      assert_receive {:completed, _agent_id, _result}, 1000
    end

    test "respects timeout parameter" do
      agents = [create_test_agent(), create_test_agent()]

      # With fast mock, this succeeds
      assert {:ok, results} = Reactive.some(agents, "test", count: 2, timeout: 5000)
      assert map_size(results) == 2
    end
  end

  describe "map/3" do
    test "transforms successful result" do
      agent = create_test_agent()

      result =
        Reactive.map(agent, "test", fn
          {:ok, response} -> {:ok, Map.put(response, :transformed, true)}
          error -> error
        end)

      assert {:ok, response} = result
      assert response.transformed == true
    end

    test "works with agent process" do
      pid = create_agent_process()

      result =
        Reactive.map(pid, "test", fn
          {:ok, _response} -> {:ok, :success}
          error -> error
        end)

      assert {:ok, :success} = result

      AgentProcess.stop(pid)
    end

    test "can transform result to different type" do
      agent = create_test_agent()

      result =
        Reactive.map(agent, "test", fn
          {:ok, _response} -> {:ok, :transformed}
          error -> error
        end)

      assert {:ok, :transformed} = result
    end

    test "can extract specific fields" do
      agent = create_test_agent()

      result =
        Reactive.map(agent, "test", fn
          {:ok, response} when is_map(response) ->
            {:ok, :valid_map}

          {:ok, _other} ->
            {:error, :invalid_format}

          error ->
            error
        end)

      assert {:ok, :valid_map} = result
    end
  end

  # Note: when_result macro tests are skipped due to macro compilation complexity in test environment
  # The macro works correctly in real usage as shown in the module documentation

  describe "concurrent execution" do
    test "race handles many agents efficiently" do
      agents = for _ <- 1..20, do: create_test_agent()

      assert {:ok, _result} = Reactive.race(agents, "test", timeout: 5000)
    end

    test "all executes agents concurrently" do
      agents = for _ <- 1..10, do: create_test_agent()

      assert {:ok, results} = Reactive.all(agents, "test", timeout: 5000)
      assert map_size(results) == 10
    end

    test "some completes as soon as N successes reached" do
      agents = for _ <- 1..10, do: create_test_agent()

      assert {:ok, results} = Reactive.some(agents, "test", count: 5, timeout: 5000)
      assert map_size(results) == 5
    end
  end

  describe "error handling" do
    test "race handles multiple agents without errors" do
      # Mock doesn't crash, but tests mechanism works
      agents = [create_test_agent(), create_test_agent()]

      assert {:ok, _result} = Reactive.race(agents, "test")
    end

    test "all collects all results" do
      # Mock doesn't error, but tests collection works
      agents = [create_test_agent(), create_test_agent()]

      assert {:ok, results} = Reactive.all(agents, "test")
      assert map_size(results) == 2
    end

    test "some waits for required count" do
      agents = [create_test_agent(), create_test_agent(), create_test_agent()]

      assert {:ok, results} = Reactive.some(agents, "test", count: 2)
      assert map_size(results) == 2
    end
  end

  describe "input handling" do
    test "race handles different input types" do
      agents = [create_test_agent(), create_test_agent()]

      # String
      assert {:ok, _} = Reactive.race(agents, "string input")

      # Map with chat_message
      assert {:ok, _} = Reactive.race(agents, %{chat_message: "map input"})

      # A map without chat_message is rejected by the default input schema. race
      # reports only :all_failed; each agent's ValidationError reaches on_complete.
      test_pid = self()

      assert {:error, :all_failed} =
               Reactive.race(agents, %{custom: "data"},
                 on_complete: fn id, result -> send(test_pid, {:race_done, id, result}) end
               )

      for id <- ["agent_0", "agent_1"] do
        assert_receive {:race_done, ^id, {:error, %Normandy.Schema.ValidationError{}}}
      end
    end

    test "all handles different input types" do
      agents = [create_test_agent(), create_test_agent()]

      assert {:ok, _} = Reactive.all(agents, "string")
      assert {:ok, _} = Reactive.all(agents, %{chat_message: "msg"})
      assert {:ok, results} = Reactive.all(agents, %{data: 42})
      assert map_size(results) == 2

      assert Enum.all?(
               Map.values(results),
               &match?({:error, %Normandy.Schema.ValidationError{}}, &1)
             )
    end

    test "some handles different input types" do
      agents = [create_test_agent(), create_test_agent()]

      assert {:ok, _} = Reactive.some(agents, "string", count: 1)
      assert {:ok, _} = Reactive.some(agents, %{chat_message: "msg"}, count: 1)
      # some reports only :insufficient_successes; each agent's ValidationError
      # reaches on_complete.
      test_pid = self()

      assert {:error, :insufficient_successes} =
               Reactive.some(agents, %{data: 42},
                 count: 1,
                 on_complete: fn id, result -> send(test_pid, {:some_done, id, result}) end
               )

      for id <- ["agent_0", "agent_1"] do
        assert_receive {:some_done, ^id, {:error, %Normandy.Schema.ValidationError{}}}
      end
    end
  end
end
