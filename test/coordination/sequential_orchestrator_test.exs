defmodule Normandy.Coordination.SequentialOrchestratorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{AgentMessage, SequentialOrchestrator}
  alias Normandy.OrchestrationError
  alias Normandy.Test.TaggingClient

  @moduletag :capture_log

  defp agent(name, opts \\ []) do
    BaseAgent.init(%{client: struct(TaggingClient, [name: name] ++ opts), model: "test-model"})
  end

  defp failing_pipeline,
    do: [
      %{id: "a", agent: agent("a")},
      %{id: "b", agent: agent("b", fail_on: "a(")},
      %{id: "c", agent: agent("c")}
    ]

  describe "execute/3" do
    test "each agent receives the previous agent's output" do
      specs = [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b")}]

      assert {:ok, %{"a" => first, "b" => second}} =
               SequentialOrchestrator.execute(specs, "start")

      assert first.chat_message =~ ~r/^a\(.*start.*\)$/
      assert second.chat_message =~ ~r/^b\(.*a\(.*start/
    end

    test "a :transform shapes the result and what the next agent receives" do
      specs = [
        %{id: "a", agent: agent("a"), transform: fn r -> "only " <> r.chat_message end},
        %{id: "b", agent: agent("b")}
      ]

      assert {:ok, %{"a" => "only a(" <> _ = first, "b" => second}} =
               SequentialOrchestrator.execute(specs, "start", on_error: :stop)

      assert first =~ "start"
      assert second.chat_message =~ ~r/^b\(.*only a\(/
    end

    test "on_agent_complete is called after each agent, in order, with its output" do
      parent = self()
      specs = [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b")}]

      {:ok, _} =
        SequentialOrchestrator.execute(specs, "x",
          on_agent_complete: fn id, output -> send(parent, {:done, id, output.chat_message}) end
        )

      assert_received {:done, "a", "a(" <> _}
      assert_received {:done, "b", "b(" <> _}
      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "on_error: :stop ends at the failing agent; the agents after it do not run" do
      assert {:error, %OrchestrationError{results: results, errors: errors}} =
               SequentialOrchestrator.execute(failing_pipeline(), "x", on_error: :stop)

      assert %{"a" => %{chat_message: "a(" <> _}} = results
      assert map_size(results) == 1
      assert errors == %{"b" => %RuntimeError{message: "b failed"}}
    end

    test "the last output of plain agents is under the last id" do
      assert {:ok, %{"agent_1" => %{chat_message: last}}} =
               SequentialOrchestrator.execute([agent("a"), agent("b")], "go")

      assert last =~ "b("
    end

    test "the 1.x options are rejected by name" do
      for {key, value} <- [shared_context: %{}, store_intermediate: false] do
        error =
          assert_raise ArgumentError, fn ->
            SequentialOrchestrator.execute([agent("a")], "x", [{key, value}])
          end

        assert error.message =~ "Normandy.Coordination.SequentialOrchestrator.execute/3: "
        assert error.message =~ inspect(key)
      end
    end
  end

  describe "on_error: :continue" do
    test "the agent after a failure gets the last successful output; the result is an error" do
      assert {:error,
              %OrchestrationError{
                results: %{"a" => a, "c" => c},
                errors: %{"b" => %RuntimeError{message: "b failed"}}
              }} = SequentialOrchestrator.execute(failing_pipeline(), "x", on_error: :continue)

      assert a.chat_message =~ "a("
      assert c.chat_message =~ ~r/^c\(.*a\(/
      refute c.chat_message =~ "error"
    end

    test "with no failure it is {:ok, results}" do
      assert {:ok, %{"a" => _}} =
               SequentialOrchestrator.execute([%{id: "a", agent: agent("a")}], "x",
                 on_error: :continue
               )
    end
  end

  describe "execute_with_messages/3" do
    test "each agent answers the previous message with a reply addressed back" do
      first = AgentMessage.new(from: "user", to: "a", payload: %{chat_message: "hi"})
      specs = [%{id: "a", agent: agent("a")}]

      assert {:ok, [^first, reply]} = SequentialOrchestrator.execute_with_messages(specs, first)

      assert %AgentMessage{type: "response", from: "a", to: "user"} = reply
      assert reply.payload.chat_message =~ ~r/^a\(.*hi/
    end

    test "a failing agent produces an error message carrying the exception's message" do
      first = AgentMessage.new(from: "user", to: "a", payload: %{chat_message: "hi"})
      specs = [%{id: "a", agent: agent("a", fail_on: "hi")}]

      assert {:ok, [_, %AgentMessage{type: "error", from: "a", to: "user"} = error]} =
               SequentialOrchestrator.execute_with_messages(specs, first)

      assert error.payload.error == "a failed"
    end

    test "an unknown spec key raises, as in execute/3" do
      first = AgentMessage.new(from: "user", to: "a", payload: %{chat_message: "hi"})

      assert_raise ArgumentError,
                   ~r/^Normandy\.Coordination\.SequentialOrchestrator\.execute_with_messages\/3: unknown agent spec keys \[:transform\]/,
                   fn ->
                     SequentialOrchestrator.execute_with_messages(
                       [%{id: "a", agent: agent("a"), transform: & &1}],
                       first
                     )
                   end
    end

    test "rejects options" do
      first = AgentMessage.new(from: "user", to: "a", payload: %{chat_message: "hi"})

      error =
        assert_raise ArgumentError, fn ->
          SequentialOrchestrator.execute_with_messages([], first, shared_context: %{})
        end

      assert error.message =~
               "Normandy.Coordination.SequentialOrchestrator.execute_with_messages/3: "

      assert error.message =~ ":shared_context"
    end
  end
end
