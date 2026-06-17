defmodule Normandy.Agents.BaseAgentExposureTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn

  test "the Turn.Server reuse surface is exported with the expected arities" do
    exported = BaseAgent.__info__(:functions)
    assert {:non_streaming_handlers, 0} in exported
    assert {:admit_turn_input, 2} in exported
    assert {:base_agent_pipeline, 1} in exported
    assert {:turn_response_model, 1} in exported
    assert {:unwrap_tool_task_result!, 1} in exported
  end

  test "non_streaming_handlers/0 returns a fully-populated Driver.Handlers struct" do
    h = BaseAgent.non_streaming_handlers()
    assert %Turn.Driver.Handlers{} = h

    for slot <- [:call_llm, :dispatch_tools, :convert, :validate, :guard, :append, :emit] do
      assert is_function(Map.fetch!(h, slot))
    end

    assert is_function(h.compact, 3)
  end

  test "compact_turn_memory/3 with default config is a NoOp that returns memory unchanged" do
    alias Normandy.Agents.BaseAgentConfig
    alias Normandy.Components.AgentMemory

    memory =
      AgentMemory.new_memory(nil)
      |> AgentMemory.add_message("user", "hello")

    config = %BaseAgentConfig{
      model: "claude-3-5-sonnet-20241022",
      memory: memory,
      behaviours: nil
    }

    {config2, meta} =
      BaseAgent.compact_turn_memory(config, %Normandy.Agents.Turn.State{}, %{iterations_left: 3})

    assert meta.compacted == false
    assert AgentMemory.history(config2.memory) == AgentMemory.history(config.memory)
  end

  test "compact_turn_memory/3 falls back to NoOp when Config field is nil" do
    alias Normandy.Agents.BaseAgentConfig
    alias Normandy.Components.AgentMemory

    memory =
      AgentMemory.new_memory(nil)
      |> AgentMemory.add_message("user", "test input")
      |> AgentMemory.add_message("assistant", "test response")

    config = %BaseAgentConfig{
      model: "claude-3-5-sonnet-20241022",
      memory: memory,
      behaviours: %Normandy.Behaviours.Config{compactor: nil, model_catalog: nil}
    }

    initial_history = AgentMemory.history(config.memory)

    {config2, meta} =
      BaseAgent.compact_turn_memory(config, %Normandy.Agents.Turn.State{}, %{iterations_left: 3})

    assert meta.compacted == false
    assert AgentMemory.history(config2.memory) == initial_history
  end
end
