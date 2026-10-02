defmodule Normandy.Coordination.SequentialOrchestratorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{AgentMessage, SequentialOrchestrator, SharedContext}
  alias Normandy.Test.TaggingClient

  @moduletag :capture_log

  defp agent(name, opts \\ []) do
    BaseAgent.init(%{client: struct(TaggingClient, [name: name] ++ opts), model: "test-model"})
  end

  describe "execute/3 with agent specs" do
    test "each agent receives the previous agent's output" do
      specs = [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b")}]

      assert {:ok, %{success: true, results: [first, second], errors: []}} =
               SequentialOrchestrator.execute(specs, "start", [])

      assert first.chat_message =~ ~r/^a\(.*start.*\)$/
      assert second.chat_message =~ ~r/^b\(.*a\(.*start/
    end

    test "a :transform shapes what the next agent receives" do
      specs = [
        %{id: "a", agent: agent("a"), transform: fn r -> "only " <> r.chat_message end},
        %{id: "b", agent: agent("b")}
      ]

      assert {:ok, %{results: ["only a(" <> _ = first, second]}} =
               SequentialOrchestrator.execute(specs, "start", on_error: :stop)

      assert first =~ "start"
      assert second.chat_message =~ ~r/^b\(.*only a\(/
    end

    test "intermediate results are stored in the shared context under results:<id>" do
      specs = [%{id: "a", agent: agent("a")}]

      {:ok, %{context: ctx}} =
        SequentialOrchestrator.execute(specs, "x", shared_context: SharedContext.new())

      assert {:ok, %{chat_message: "a(" <> _}} = SharedContext.get(ctx, {"results", "a"})
    end

    test "store_intermediate: false leaves the context untouched" do
      specs = [%{id: "a", agent: agent("a")}]

      {:ok, %{context: ctx}} =
        SequentialOrchestrator.execute(specs, "x", store_intermediate: false)

      assert SharedContext.keys(ctx) == []
    end

    test "on_agent_complete is called after each agent, in order" do
      parent = self()
      specs = [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b")}]

      {:ok, _} =
        SequentialOrchestrator.execute(specs, "x",
          on_agent_complete: fn id, _result, _ctx -> send(parent, {:done, id}) end
        )

      assert_received {:done, "a"}
      assert_received {:done, "b"}
      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "on_error: :stop halts at the failing agent and keeps earlier results" do
      specs = [
        %{id: "a", agent: agent("a")},
        %{id: "b", agent: agent("b", fail_on: "a(")},
        %{id: "c", agent: agent("c")}
      ]

      assert {:error, %{success: false, results: [%{chat_message: "a(" <> _}], errors: [error]}} =
               SequentialOrchestrator.execute(specs, "x", on_error: :stop)

      assert %{agent_id: "b", error: {:exception, %RuntimeError{message: "b failed"}, _}} = error
    end
  end

  describe "an agent that exits" do
    test "is the step's error, not an exit of the caller" do
      exiting =
        BaseAgent.init(%{
          client: %Normandy.Test.StubClient{reply: fn _ -> exit(:boom) end},
          model: "test-model"
        })

      assert {:error, %{errors: [%{agent_id: "e", error: {:exit, :boom}}]}} =
               SequentialOrchestrator.execute([%{id: "e", agent: exiting}], "x")
    end
  end

  describe "on_error: :continue" do
    test "the agent after a failure gets the last successful output; the failure stays in results" do
      specs = [
        %{id: "a", agent: agent("a")},
        %{id: "b", agent: agent("b", fail_on: "a(")},
        %{id: "c", agent: agent("c")}
      ]

      assert {:ok, %{results: [a, {:error, {:exception, %RuntimeError{}, _}}, c]}} =
               SequentialOrchestrator.execute(specs, "x", on_error: :continue)

      assert a.chat_message =~ "a("
      assert c.chat_message =~ ~r/^c\(.*a\(/
      refute c.chat_message =~ "error"
    end

    test "a failure makes success false and is listed in errors" do
      specs = [
        %{id: "a", agent: agent("a")},
        %{id: "b", agent: agent("b", fail_on: "a(")},
        %{id: "c", agent: agent("c")}
      ]

      assert {:ok, %{success: false, errors: [%{agent_id: "b", error: {:exception, _, _}}]}} =
               SequentialOrchestrator.execute(specs, "x", on_error: :continue)

      assert {:ok, %{success: true, errors: []}} =
               SequentialOrchestrator.execute([%{id: "a", agent: agent("a")}], "x",
                 on_error: :continue
               )
    end
  end

  describe "execute/2 with plain agents" do
    test "returns the last agent's result" do
      assert {:ok, %{chat_message: last}} =
               SequentialOrchestrator.execute([agent("a"), agent("b")], "go")

      assert last =~ "b("
    end

    test "a failure is returned as an error, not raised" do
      assert {:error, %{errors: [%{agent_id: "agent_1"}]}} =
               SequentialOrchestrator.execute([agent("a"), agent("b", fail_on: "a(")], "go")
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

    test "a failing agent produces an error message" do
      first = AgentMessage.new(from: "user", to: "a", payload: %{chat_message: "hi"})
      specs = [%{id: "a", agent: agent("a", fail_on: "hi")}]

      assert {:ok, [_, %AgentMessage{type: "error", from: "a", to: "user"}]} =
               SequentialOrchestrator.execute_with_messages(specs, first)
    end
  end
end
