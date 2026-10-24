defmodule Normandy.Agents.BaseAgentExposureTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Agents.Turn

  test "the Turn.Server reuse surface is exported with the expected arities" do
    exported = AgentHandlers.__info__(:functions)
    assert {:non_streaming_handlers, 0} in exported
    assert {:admit_turn_input, 2} in exported
    assert {:base_agent_pipeline, 1} in exported
    assert {:turn_response_model, 1} in exported
  end

  # principles-audit agents#3: the facade holds the public API only; the engine the
  # shells share lives in BaseAgent.Handlers and the init checks in BaseAgent.InitOptions.
  test "BaseAgent has no hidden functions" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(BaseAgent)
    hidden = for {{kind, name, arity}, _, _, :hidden, _} <- docs, do: {kind, name, arity}
    assert hidden == []
  end

  test "non_streaming_handlers/0 returns a fully-populated Driver.Handlers struct" do
    h = AgentHandlers.non_streaming_handlers()
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
      AgentHandlers.compact_turn_memory(config, %Normandy.Agents.Turn.State{}, %{
        iterations_left: 3,
        mid_round: false
      })

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
      AgentHandlers.compact_turn_memory(config, %Normandy.Agents.Turn.State{}, %{
        iterations_left: 3,
        mid_round: false
      })

    assert meta.compacted == false
    assert AgentMemory.history(config2.memory) == initial_history
  end
end
