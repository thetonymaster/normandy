defmodule Normandy.Coordination.OrchestratorContractTest do
  @moduledoc """
  Every orchestrator's execute/3 returns {:ok, %{agent_id => output}} when each agent
  succeeded and {:error, %Normandy.OrchestrationError{}} otherwise. A new orchestrator
  joins @orchestrators.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Coordination.{ParallelOrchestrator, SequentialOrchestrator}
  alias Normandy.OrchestrationError
  alias Normandy.Test.{StubClient, TaggingClient}
  alias Normandy.TurnError

  @moduletag :capture_log

  @orchestrators [SequentialOrchestrator, ParallelOrchestrator]

  defp agent(name, opts \\ []),
    do:
      BaseAgent.init(%{client: struct(TaggingClient, [name: name] ++ opts), model: "test-model"})

  for orchestrator <- @orchestrators do
    describe "#{inspect(orchestrator)}.execute/3" do
      @orchestrator orchestrator

      test "every agent succeeds: {:ok, outputs keyed by spec id}" do
        assert {:ok, results} =
                 @orchestrator.execute(
                   [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b")}],
                   "go"
                 )

        assert results |> Map.keys() |> Enum.sort() == ["a", "b"]
        assert results["a"].chat_message =~ "a("
        assert results["b"].chat_message =~ "b("
      end

      test "bare agents are keyed agent_0, agent_1, ... in list order" do
        assert {:ok, results} = @orchestrator.execute([agent("a"), agent("b")], "go")
        assert results |> Map.keys() |> Enum.sort() == ["agent_0", "agent_1"]
        assert results["agent_0"].chat_message =~ "a("
        assert results["agent_1"].chat_message =~ "b("
      end

      test "a struct input reaches the first agent" do
        assert {:ok, %{"agent_0" => %{chat_message: "a(x)"}}} =
                 @orchestrator.execute(
                   [agent("a"), agent("b")],
                   %BaseAgentInputSchema{chat_message: "x"}
                 )
      end

      test "a caller that traps exits finds its mailbox empty afterwards" do
        Process.flag(:trap_exit, true)
        assert {:ok, _} = @orchestrator.execute([agent("a"), agent("b")], "go")
        assert Process.info(self(), :messages) == {:messages, []}
      end

      test "a :transform or :on_agent_complete that raises is that agent's error" do
        boom = fn _ -> raise "transform boom" end

        assert {:error, %OrchestrationError{errors: %{"a" => %RuntimeError{}}}} =
                 @orchestrator.execute([%{id: "a", agent: agent("a"), transform: boom}], "go")

        assert {:error, %OrchestrationError{errors: %{"a" => %RuntimeError{}}}} =
                 @orchestrator.execute([%{id: "a", agent: agent("a")}], "go",
                   on_agent_complete: fn _id, _output -> raise "callback boom" end
                 )
      end

      test "a :transform that is not a 1-arity function raises before any agent runs" do
        for bad <- [nil, fn a, b -> {a, b} end] do
          error =
            assert_raise ArgumentError, fn ->
              @orchestrator.execute([%{id: "a", agent: agent("a"), transform: bad}], "go")
            end

          assert error.message =~ "#{inspect(@orchestrator)}.execute/3: :transform for \"a\""
          assert error.message =~ "must be a 1-arity function"
        end
      end

      test "no agents: {:ok, %{}}" do
        assert {:ok, %{}} = @orchestrator.execute([], "go")
      end

      test "a failing agent: {:error, %OrchestrationError{}} keeping the other outputs" do
        assert {:error, %OrchestrationError{results: results, errors: errors} = error} =
                 @orchestrator.execute(
                   [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b", fail_on: "go")}],
                   "go"
                 )

        assert Map.keys(results) == ["a"]
        assert %{"b" => %RuntimeError{message: "b failed"}} = errors
        assert Exception.message(error) == ~s|1 agent(s) failed: "b" (RuntimeError)|
      end

      test "an agent that exits fails with a :task_down TurnError, not an exit of the caller" do
        exiting =
          BaseAgent.init(%{
            client: %StubClient{reply: fn _ -> exit(:boom) end},
            model: "test-model"
          })

        assert {:error,
                %OrchestrationError{errors: %{"e" => %TurnError{type: :task_down, reason: :boom}}}} =
                 @orchestrator.execute([%{id: "e", agent: exiting}], "x")
      end

      test "a throwing agent fails with a :task_down TurnError; the caller lives" do
        thrower =
          BaseAgent.init(%{
            client: %StubClient{reply: fn _ -> throw(:oops) end},
            model: "test-model"
          })

        assert {:error,
                %OrchestrationError{
                  results: %{"ok" => _},
                  errors: %{"t" => %TurnError{type: :task_down, reason: {:nocatch, :oops}}}
                }} =
                 @orchestrator.execute(
                   [%{id: "ok", agent: agent("ok")}, %{id: "t", agent: thrower}],
                   "x"
                 )
      end

      test "a crash in a process an agent linked to fails that agent; the caller lives" do
        linker =
          BaseAgent.init(%{
            client: %StubClient{
              reply: fn _ ->
                spawn_link(fn -> raise "helper" end)
                Process.sleep(1_000)
              end
            },
            model: "test-model"
          })

        assert {:error,
                %OrchestrationError{
                  results: %{"ok" => _},
                  errors: %{"l" => %TurnError{type: :task_down}}
                }} =
                 @orchestrator.execute(
                   [%{id: "ok", agent: agent("ok")}, %{id: "l", agent: linker}],
                   "x"
                 )
      end

      test "no task supervisor is left behind, after a run or a raise on bad input" do
        owner = self()

        # Processes the test process started: capture_log's StringIO is one.
        started = fn ->
          Enum.filter(Process.list(), fn pid ->
            case Process.info(pid, :dictionary) do
              {:dictionary, dict} -> owner in List.wrap(dict[:"$ancestors"])
              nil -> false
            end
          end)
        end

        before = started.()

        assert {:ok, _} = @orchestrator.execute([agent("a")], "x")
        assert started.() == before

        assert_raise ArgumentError, fn -> @orchestrator.execute([agent("a")], "x", bogus: 1) end
        assert started.() == before
      end

      test "a repeated id raises before any agent runs" do
        assert_raise ArgumentError,
                     "#{inspect(@orchestrator)}.execute/3: agent ids must be unique, " <>
                       ~s(got ["a"] more than once),
                     fn ->
                       @orchestrator.execute(
                         [%{id: "a", agent: agent("a")}, %{id: "a", agent: agent("b")}],
                         "x"
                       )
                     end
      end

      test "something that is not an agent raises naming its position" do
        error =
          assert_raise ArgumentError, fn ->
            @orchestrator.execute([agent("a"), %{agent: agent("b")}], "x")
          end

        assert error.message =~
                 "#{inspect(@orchestrator)}.execute/3: agent 1 must be a " <>
                   "%Normandy.Agents.BaseAgentConfig{} or a spec"

        assert error.message =~ "got: a map"
      end

      test "an unknown spec key raises naming it" do
        error =
          assert_raise ArgumentError, fn ->
            @orchestrator.execute([%{id: "a", agent: agent("a"), retries: 3}], "x")
          end

        assert error.message =~
                 "#{inspect(@orchestrator)}.execute/3: unknown agent spec keys [:retries]"
      end

      test "an unknown option names the function and the key" do
        error =
          assert_raise ArgumentError, fn ->
            @orchestrator.execute([agent("a")], "x", shared_context: :ctx)
          end

        assert error.message =~ "#{inspect(@orchestrator)}.execute/3: "
        assert error.message =~ ":shared_context"
      end
    end
  end
end
