defmodule Normandy.Integration.CompactionTurnTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.Config
  alias Normandy.Components.AgentMemory

  defp big_memory do
    Enum.reduce(1..60, AgentMemory.new_memory(nil), fn i, m ->
      AgentMemory.add_message(m, "user", "padded conversation message number #{i} text")
    end)
  end

  test "default (NoOp) compactor leaves memory untouched at the steering boundary" do
    config = %BaseAgentConfig{
      model: "claude-3-5-sonnet-20241022",
      memory: big_memory(),
      behaviours: %Config{}
    }

    {config2, meta} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3})

    assert meta.compacted == false
    assert AgentMemory.history(config2.memory) == AgentMemory.history(config.memory)
  end

  test "opt-in WindowManager compactor with a tiny window truncates at the boundary" do
    config = %BaseAgentConfig{
      model: "claude-3-5-sonnet-20241022",
      memory: big_memory(),
      behaviours: %Config{
        compactor: {Compactor.WindowManager, [max_tokens: 80, reserved_tokens: 16]}
      }
    }

    {config2, meta} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3})

    assert meta.compacted == true
    assert meta.tokens_after < meta.tokens_before

    assert length(AgentMemory.history(config2.memory)) <
             length(AgentMemory.history(config.memory))
  end
end
