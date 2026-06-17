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
  end
end
