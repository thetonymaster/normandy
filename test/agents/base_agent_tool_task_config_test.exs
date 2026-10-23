defmodule Normandy.Agents.BaseAgentToolTaskConfigTest do
  @moduledoc """
  B2 on the BaseAgent path (principles-audit agents#1): `run/3` and `stream/3` run each
  tool task with a config whose memory has no entries, so a batch does not copy the
  conversation once per tool, as `Turn.Server` does. The turn id stays, and
  classification (policy, before-hooks) still sees the whole conversation.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Behaviours.Config
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Test.{ContextProbe, FakeClient}

  defp agent(test_pid) do
    calls = [
      %ToolCall{id: "c1", name: "probe", input: %{}},
      %ToolCall{id: "c2", name: "probe", input: %{}}
    ]

    behaviours = %Config{
      before_hooks: [
        fn config, call ->
          send(test_pid, {:before_hook_entries, call.id, map_size(config.memory.entries)})
          {:cont, call}
        end
      ],
      after_hooks: [
        fn config, call, %ToolResult{} = result ->
          send(
            test_pid,
            {:after_hook, call.id, map_size(config.memory.entries), config.memory.current_turn_id}
          )

          result
        end
      ]
    }

    %{
      client: FakeClient.new([{:tool_calls, calls}, {:text, "done"}]),
      model: "test",
      max_tool_concurrency: 2,
      behaviours: behaviours
    }
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%ContextProbe{notify: test_pid})
  end

  defp assert_slim_batch do
    for id <- ["c1", "c2"] do
      assert_received {:before_hook_entries, ^id, entries} when entries > 0
      assert_received {:after_hook, ^id, 0, turn_id} when is_binary(turn_id)
    end
  end

  test "run/3 runs each tool task with no entries; its before-hook saw them" do
    assert {:ok, _config, _response} = BaseAgent.run(agent(self()), %{chat_message: "go"})
    assert_slim_batch()
  end

  test "stream/3 runs each tool task with no entries; its before-hook saw them" do
    assert {:ok, _config, _response} =
             BaseAgent.stream(agent(self()), %{chat_message: "go"}, fn _ -> :ok end)

    assert_slim_batch()
  end
end
