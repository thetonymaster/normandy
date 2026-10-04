defmodule Normandy.Hooks.ContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory
  alias Normandy.Hooks.Context

  test "builds the event, names, model and values; the turn id comes from memory" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()

    config = %{
      name: "a",
      model: "m",
      session_id: "s",
      memory: memory,
      tool_context: %{user: 1},
      client: %{api_key: "sk-secret"}
    }

    ctx = Context.build(config, :after_tool)

    assert %Context{
             event: :after_tool,
             agent_name: "a",
             model: "m",
             session_id: "s",
             values: %{user: 1}
           } = ctx

    assert ctx.turn_id == memory.current_turn_id
    refute is_nil(ctx.turn_id)
    refute inspect(ctx) =~ "sk-secret"
  end

  test "turn_id: nil forces no turn id; missing fields default" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    assert %Context{turn_id: nil} = Context.build(%{memory: memory}, :on_prompt, turn_id: nil)

    assert %Context{values: %{}, session_id: nil, agent_name: nil, model: nil, turn_id: nil} =
             Context.build(%{}, :on_passivate)
  end

  test "the context carries no config" do
    refute Map.has_key?(%Context{}, :config)
  end
end
