defmodule Normandy.Agents.Turn.ServerToolTaskConfigTest do
  @moduledoc """
  Task 6.2e (B2): `Turn.Server` runs each tool task with a config whose memory has no
  entries, so a batch does not copy the conversation once per tool. The turn id stays,
  and classification (policy, before-hooks) still sees the whole conversation.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, ToolCall, ToolResult}
  alias Normandy.Test.Eventually
  alias Normandy.Tools.Toolset

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # Reports the turn id its Tools.Context carries.
  defmodule TurnIdTool do
    use Normandy.Tool, name: "probe", description: "reports its context"

    defstruct notify: nil

    @impl Normandy.Tool
    def input_schema(_tool), do: %{type: "object", properties: %{}}

    @impl Normandy.Tool
    def run(%__MODULE__{notify: pid}, %Normandy.Tools.Context{turn_id: turn_id}) do
      send(pid, {:tool_turn_id, turn_id})
      {:ok, "ok"}
    end
  end

  defp config(test_pid, policy) do
    behaviours = %Config{
      policy: policy,
      before_hooks: [
        fn config, call ->
          send(test_pid, {:before_hook_entries, map_size(config.memory.entries)})
          {:cont, call}
        end
      ],
      after_hooks: [
        fn config, _call, %ToolResult{} = result ->
          send(
            test_pid,
            {:after_hook, map_size(config.memory.entries), config.memory.current_turn_id}
          )

          result
        end
      ]
    }

    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      toolset: Toolset.new([%TurnIdTool{notify: test_pid}]),
      behaviours: behaviours
    }
  end

  defp start(config, sid) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn _config, _state, _request ->
      if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0,
        do: %Resp{tool_calls: [%ToolCall{id: "p1", name: "probe", input: %{}}]},
        else: %Resp{content: "done"}
    end

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
      )

    srv
  end

  test "a dispatched tool runs with no entries and the turn's id; its before-hook saw them" do
    srv = start(config(self(), {Normandy.Behaviours.PolicyEngine.AllowAll, []}), "slim-dispatch")

    assert {:ok, %Resp{content: "done"}} = Turn.Server.run(srv, "go")

    # Classification ran in the worker with the conversation (user + assistant).
    assert_received {:before_hook_entries, 2}
    assert_received {:after_hook, 0, turn_id} when is_binary(turn_id)
    assert_received {:tool_turn_id, ^turn_id}

    {:idle, data} = :sys.get_state(srv)
    assert data.config.memory.current_turn_id == turn_id
  end

  test "an approved call runs with no entries too" do
    policy =
      {Normandy.Behaviours.PolicyEngine.Ruleset,
       rules: [%{match: "probe", action: :require_approval, rule_id: "R1"}],
       default_action: :allow}

    srv = start(config(self(), policy), "slim-approved")
    caller = Task.async(fn -> Turn.Server.run(srv, "go") end)

    assert Eventually.wait_until(fn ->
             match?({:awaiting_approval, _}, :sys.get_state(srv))
           end)

    :ok = Turn.Server.approve(srv, %{"p1" => :approve})

    assert {:ok, %Resp{content: "done"}} = Task.await(caller, 5_000)
    assert_received {:after_hook, 0, turn_id} when is_binary(turn_id)
    assert_received {:tool_turn_id, ^turn_id}
  end
end
