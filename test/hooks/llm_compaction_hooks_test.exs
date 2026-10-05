defmodule Normandy.Hooks.LlmCompactionHooksTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter
  alias Normandy.Behaviours.Config
  alias Normandy.Components.{AgentMemory, Message, ToolResult}
  alias Normandy.Test.{ContextProbe, KeepLastCompactor, StreamingProbeClient, StubClient}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe

  defp probe(opts \\ []), do: {Probe, [notify: TestHooks.sink(), tag: :p] ++ opts}
  defp input(text), do: %BaseAgentInputSchema{chat_message: text}

  defp agent(behaviours, extra \\ %{}) do
    %{
      client: %StubClient{notify: self()},
      model: "test",
      name: "llm-hooks-agent",
      behaviours: behaviours
    }
    |> Map.merge(extra)
    |> BaseAgent.init()
  end

  # Every message in the mailbox, in arrival order.
  defp mailbox do
    receive do
      msg -> [msg | mailbox()]
    after
      0 -> []
    end
  end

  defp seeded_memory do
    AgentMemory.new_memory()
    |> AgentMemory.add_message("user", "old-1")
    |> AgentMemory.add_message("assistant", "old-2")
    |> AgentMemory.add_message("user", "old-3")
  end

  # keep: 2 at turn start holds old-3 and the new input; the rest is dropped.
  defp keep_two(hooks),
    do: %Config{compactor: {KeepLastCompactor, keep: 2, max_tokens: 200_000}, hooks: hooks}

  describe "before_llm" do
    test "runs before each LLM call with the call's info" do
      BaseAgent.run(agent(%Config{hooks: [probe()]}), input("hi"))

      assert [
               {:hook, :p, :before_llm, [%{final: false, iterations_left: left}, _ctx]},
               {:converse, _, _}
             ] =
               Enum.filter(
                 mailbox(),
                 &(match?({:hook, :p, :before_llm, _}, &1) or match?({:converse, _, _}, &1))
               )

      assert is_integer(left)
    end

    test "a halt raises HookHaltError, skips the LLM and reports the halt at turn end" do
      agent = agent(%Config{hooks: [probe(returns: [before_llm: {:halt, "budget spent"}])]})

      error = assert_raise Normandy.HookHaltError, fn -> BaseAgent.run(agent, input("hi")) end

      assert %Normandy.HookHaltError{event: :before_llm, hook: Probe, reason: "budget spent"} =
               error

      refute_received {:converse, _, _}
      assert_received {:hook, :p, :on_turn_end, [{:error, {:hook_halted, ^error}}, _ctx]}
    end

    test "runs on the streaming path, once per LLM call" do
      config =
        %{
          client: %StreamingProbeClient{},
          model: "test",
          name: "llm-hooks-stream",
          behaviours: %Config{hooks: [probe()]}
        }
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%ContextProbe{})

      BaseAgent.stream_with_tools(config, input("go"), fn _, _ -> :ok end)

      # StreamingProbeClient makes two calls: the tool_use round, then the text answer.
      assert_received {:hook, :p, :before_llm, _}
      assert_received {:hook, :p, :before_llm, _}
      refute_received {:hook, :p, :before_llm, _}
    end
  end

  test "a before_llm halt on the streaming path raises HookHaltError and fires on_turn_end once" do
    config =
      %{
        client: %StreamingProbeClient{},
        model: "test",
        name: "llm-hooks-stream-halt",
        behaviours: %Config{hooks: [probe(returns: [before_llm: {:halt, "budget spent"}])]}
      }
      |> BaseAgent.init()
      |> BaseAgent.register_tool(%ContextProbe{})

    error =
      assert_raise Normandy.HookHaltError, fn ->
        BaseAgent.stream_with_tools(config, input("go"), fn _, _ -> :ok end)
      end

    assert %Normandy.HookHaltError{event: :before_llm, hook: Probe, reason: "budget spent"} =
             error

    assert_received {:hook, :p, :on_turn_end, [{:error, {:hook_halted, ^error}}, _ctx]}
    refute_received {:hook, :p, :on_turn_end, _}
  end

  describe "after_compact" do
    test "receives the compactor's dropped entries, with their ids, and meta without :dropped" do
      memory = seeded_memory()
      [old1, old2, _old3] = AgentMemory.entry_chain(memory)

      BaseAgent.run(agent(keep_two([probe()]), %{memory: memory}), input("now"))

      assert_received {:hook, :p, :after_compact, [dropped, meta, _ctx]}
      assert dropped == [old1, old2]
      assert meta.compacted
      refute Map.has_key?(meta, :dropped)
    end

    test "injected texts are appended to the compacted memory, before the LLM call" do
      hooks = [probe(returns: [after_compact: {:inject, ["remember: prefers metric"]}])]

      {config, _response} =
        BaseAgent.run(agent(keep_two(hooks), %{memory: seeded_memory()}), input("now"))

      contents = config.memory |> AgentMemory.messages() |> Enum.map(& &1.content)

      assert [
               "old-3",
               %BaseAgentInputSchema{chat_message: "now"},
               "remember: prefers metric" | _assistant
             ] = contents

      assert_received {:converse, %Normandy.LLM.Request{messages: messages}, _opts}
      assert Enum.any?(messages, &(&1.content == "remember: prefers metric"))
    end

    test "does not fire when the compactor dropped nothing" do
      behaviours = %Config{
        compactor: {KeepLastCompactor, keep: 100, max_tokens: 200_000},
        hooks: [probe()]
      }

      BaseAgent.run(agent(behaviours), input("hi"))
      refute_received {:hook, :p, :after_compact, _}
    end

    test "Compactor.WindowManager: dropped is exactly what :oldest_first removed, by id" do
      memory =
        Enum.reduce(1..40, AgentMemory.new_memory(), fn i, m ->
          AgentMemory.add_message(m, "user", "message number #{i} padding")
        end)

      seeded_ids = memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id)

      behaviours = %Config{
        compactor:
          {Normandy.Behaviours.Compactor.WindowManager, max_tokens: 80, reserved_tokens: 16},
        hooks: [probe()]
      }

      {config, _response} = BaseAgent.run(agent(behaviours, %{memory: memory}), input("now"))

      assert_received {:hook, :p, :after_compact, [dropped, _meta, _ctx]}
      dropped_ids = Enum.map(dropped, & &1.id)
      kept_ids = config.memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id)

      assert dropped != []
      assert dropped_ids == Enum.take(seeded_ids, length(dropped_ids))
      assert MapSet.disjoint?(MapSet.new(dropped_ids), MapSet.new(kept_ids))
    end

    test "the adapter neither merges nor drops consecutive user messages" do
      messages =
        AgentMemory.new_memory()
        |> AgentMemory.add_message("user", "hi")
        |> AgentMemory.add_message("tool", %ToolResult{
          tool_call_id: "toolu_1",
          output: "ok",
          is_error: false
        })
        |> AgentMemory.add_message("user", "remember: prefers metric")
        |> AgentMemory.history()
        |> Enum.map(fn %{role: role, content: content} ->
          %Message{role: role, content: content}
        end)

      request =
        ClaudioAdapter.add_messages(
          Request.new("m"),
          messages,
          false
        )

      assert Enum.map(request.messages, & &1["role"]) == ["user", "user", "user"]
    end
  end
end
