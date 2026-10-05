defmodule Normandy.Coordination.ParallelOrchestratorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Coordination.ParallelOrchestrator
  alias Normandy.OrchestrationError
  alias Normandy.Test.{StubClient, TaggingClient}
  alias Normandy.TurnError

  @moduletag :capture_log

  defp tagging(name, opts \\ []) do
    BaseAgent.init(%{client: struct(TaggingClient, [name: name] ++ opts), model: "test-model"})
  end

  # An agent whose model call exits (as a timed-out GenServer.call does) instead of raising.
  defp exiting_agent,
    do:
      BaseAgent.init(%{client: %StubClient{reply: fn _ -> exit(:boom) end}, model: "test-model"})

  describe "execute/3 input" do
    test "a struct input reaches every agent" do
      assert {:ok, %{"agent_0" => a, "agent_1" => b}} =
               ParallelOrchestrator.execute(
                 [tagging("a"), tagging("b")],
                 %BaseAgentInputSchema{chat_message: "x"}
               )

      assert a.chat_message == "a(x)"
      assert b.chat_message == "b(x)"
    end

    test "a string or a chat_message map reaches every agent" do
      specs = [%{id: "a", agent: tagging("a")}, %{id: "b", agent: tagging("b")}]

      for input <- ["x", %{chat_message: "x"}] do
        assert {:ok, %{"a" => %{chat_message: "a(x)"}, "b" => %{chat_message: "b(x)"}}} =
                 ParallelOrchestrator.execute(specs, input)
      end
    end

    test "the 1.x execute(specs, opts) form raises instead of ignoring the options" do
      assert_raise ArgumentError,
                   "Normandy.Coordination.ParallelOrchestrator.execute/3: the second argument " <>
                     "is the input, got a keyword list of options [:timeout, :ordered]; options " <>
                     "go third, execute(agents, input, opts) (see MIGRATING-2.0.md §27)",
                   fn ->
                     ParallelOrchestrator.execute([tagging("a")], timeout: 100, ordered: true)
                   end
    end

    test "a spec's :input replaces the shared input for that agent" do
      specs = [%{id: "a", agent: tagging("a"), input: "one"}, %{id: "b", agent: tagging("b")}]

      assert {:ok, %{"a" => %{chat_message: "a(one)"}, "b" => %{chat_message: "b(two)"}}} =
               ParallelOrchestrator.execute(specs, "two")
    end

    test "a :transform shapes the agent's output" do
      specs = [
        %{id: "a", agent: tagging("a"), transform: &String.upcase(&1.chat_message)}
      ]

      assert {:ok, %{"a" => "A(X)"}} = ParallelOrchestrator.execute(specs, "x")
    end
  end

  describe "execute/3 options" do
    test ":on_agent_complete is called once per successful agent with its output" do
      parent = self()
      specs = [%{id: "a", agent: tagging("a")}, %{id: "b", agent: tagging("b")}]

      {:ok, _} =
        ParallelOrchestrator.execute(specs, "x",
          on_agent_complete: fn id, output -> send(parent, {:done, id, output.chat_message}) end
        )

      assert_received {:done, "a", "a(x)"}
      assert_received {:done, "b", "b(x)"}
    end

    test "an agent past :timeout fails with a :task_down TurnError; the others still finish" do
      specs = [
        %{id: "fast", agent: tagging("fast")},
        %{id: "slow", agent: tagging("slow", sleep_ms: 500)}
      ]

      assert {:error,
              %OrchestrationError{
                results: %{"fast" => _},
                errors: %{"slow" => %TurnError{type: :task_down, reason: :timeout}}
              }} = ParallelOrchestrator.execute(specs, "x", timeout: 100)
    end

    test "agents run concurrently" do
      specs = for n <- 1..4, do: %{id: "#{n}", agent: tagging("#{n}", sleep_ms: 200)}
      start = System.monotonic_time(:millisecond)

      {:ok, _} = ParallelOrchestrator.execute(specs, "x", max_concurrency: 4)

      # Four 200 ms agents in sequence would take 800 ms.
      assert System.monotonic_time(:millisecond) - start < 600
    end

    test "the 1.x options are rejected by name" do
      for {key, value} <- [shared_context: %{}, aggregate: &Function.identity/1, ordered: true] do
        error =
          assert_raise ArgumentError, fn ->
            ParallelOrchestrator.execute([tagging("a")], "x", [{key, value}])
          end

        assert error.message =~ "Normandy.Coordination.ParallelOrchestrator.execute/3: "
        assert error.message =~ inspect(key)
      end
    end
  end

  describe "callbacks that raise" do
    test "a raising :transform is the agent's error, not a crash of the caller" do
      specs = [
        %{id: "ok", agent: tagging("ok")},
        %{id: "t", agent: tagging("t"), transform: fn _ -> raise "transform failed" end}
      ]

      assert {:error,
              %OrchestrationError{
                results: %{"ok" => _},
                errors: %{"t" => %RuntimeError{message: "transform failed"}}
              }} = ParallelOrchestrator.execute(specs, "x")
    end

    test "a raising :on_agent_complete is the agent's error, not a crash of the caller" do
      assert {:error, %OrchestrationError{errors: %{"a" => %RuntimeError{message: "boom"}}}} =
               ParallelOrchestrator.execute([%{id: "a", agent: tagging("a")}], "x",
                 on_agent_complete: fn _, _ -> raise "boom" end
               )
    end

    test "execute_stream/2: a raising :transform is the agent's error" do
      specs = [%{id: "t", agent: tagging("t"), input: "x", transform: fn _ -> raise "no" end}]

      assert [{:ok, {:error, {"t", %RuntimeError{message: "no"}}}}] =
               specs |> ParallelOrchestrator.execute_stream() |> Enum.to_list()
    end
  end

  describe "execute_stream/2" do
    test "yields an exit as a :task_down TurnError" do
      specs = [%{id: "exits", agent: exiting_agent(), input: "x"}]

      assert [{:ok, {:error, {"exits", %TurnError{type: :task_down, reason: :boom}}}}] =
               specs |> ParallelOrchestrator.execute_stream() |> Enum.to_list()
    end

    test "an agent past :timeout is reported by id; the stream goes on" do
      specs = [
        %{id: "fast", agent: tagging("fast"), input: "x"},
        # Killed at the timeout; the margin keeps "fast" in time on a loaded machine.
        %{id: "slow", agent: tagging("slow", sleep_ms: 10_000), input: "x"}
      ]

      outcomes = specs |> ParallelOrchestrator.execute_stream(timeout: 1_000) |> Enum.to_list()

      assert {:exit, {"slow", :timeout}} in outcomes
      assert Enum.any?(outcomes, &match?({:ok, {:ok, {"fast", _}}}, &1))
    end

    test "yields each agent's result or error tagged with its id" do
      specs = [
        %{id: "a", agent: tagging("a"), input: "x"},
        %{id: "bad", agent: tagging("bad", fail_on: "x"), input: "x"}
      ]

      outcomes = specs |> ParallelOrchestrator.execute_stream() |> Enum.map(fn {:ok, r} -> r end)

      assert {:ok, {"a", %{chat_message: "a(" <> _}}} = Enum.find(outcomes, &match?({:ok, _}, &1))

      assert {:error, {"bad", %RuntimeError{message: "bad failed"}}} =
               Enum.find(outcomes, &match?({:error, _}, &1))
    end
  end
end
