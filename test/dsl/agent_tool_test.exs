defmodule Normandy.DSL.AgentToolTest do
  use ExUnit.Case, async: true

  alias Normandy.Test.FakeTool
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Toolset

  defmodule ToolAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      tool(Normandy.Test.FakeTool, timeout: 1_234)
      tool(Normandy.Tools.Examples.Calculator)
    end
  end

  defmodule PlainStruct do
    @moduledoc false
    defstruct []
  end

  defmodule NotAToolAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      tool(Normandy.DSL.AgentToolTest.PlainStruct)
    end
  end

  defp client, do: %NormandyTest.Support.ModelMockup{}

  test "tool registers the module's struct with its registration options" do
    agent = ToolAgent.new(client: client())

    assert {:ok, %FakeTool{}} = Toolset.fetch(agent.toolset, "weather")
    assert {:ok, %Calculator{}} = Toolset.fetch(agent.toolset, "calculator")
    assert Toolset.timeout(agent.toolset, "weather") == 1_234
    assert Toolset.timeout(agent.toolset, "calculator") == nil
  end

  test "a module that is not a Normandy.Tool raises at new/1, naming it" do
    error = assert_raise ArgumentError, fn -> NotAToolAgent.new(client: client()) end

    assert error.message =~
             "Normandy.DSL.AgentToolTest.PlainStruct does not implement the Normandy.Tool behaviour"
  end
end
