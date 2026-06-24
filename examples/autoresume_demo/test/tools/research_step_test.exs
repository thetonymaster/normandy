defmodule AutoresumeDemo.Tools.ResearchStepTest do
  use ExUnit.Case, async: true

  alias AutoresumeDemo.Tools.ResearchStep
  alias Normandy.Tools.BaseTool

  test "exposes name, description, and an object input schema" do
    t = %ResearchStep{}
    assert BaseTool.tool_name(t) == "research_step"
    assert is_binary(BaseTool.tool_description(t))
    schema = BaseTool.input_schema(t)
    assert schema["type"] == "object"
    assert "topic" in schema["required"]
  end

  test "run returns a finding for the given step (struct input)" do
    assert {:ok, %{"step" => 3, "finding" => finding}} =
             BaseTool.run(%ResearchStep{topic: "raft", n: 3})

    assert finding =~ "raft"
  end

  test "run tolerates a plain map with string keys" do
    assert {:ok, %{"step" => 2}} = BaseTool.run(%{"topic" => "paxos", "n" => 2})
  end
end
