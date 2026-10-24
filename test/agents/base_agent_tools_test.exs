defmodule NormandyTest.Agents.BaseAgentToolsTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Tools.Examples.{Calculator, StringManipulator}
  alias Normandy.Tools.Toolset

  setup do
    config = %{
      client: %NormandyTest.Support.ModelMockup{},
      model: "test-model",
      temperature: 0.7
    }

    agent = BaseAgent.init(config)
    {:ok, agent: agent}
  end

  describe "BaseAgent tool registration" do
    test "registers a tool", %{agent: agent} do
      tool = %Calculator{}
      agent = BaseAgent.register_tool(agent, tool)

      assert BaseAgent.has_tools?(agent)
      assert {:ok, ^tool} = BaseAgent.fetch_tool(agent, "calculator")
    end

    test "registers multiple tools", %{agent: agent} do
      calc = %Calculator{}
      string = %StringManipulator{}

      agent =
        agent
        |> BaseAgent.register_tool(calc)
        |> BaseAgent.register_tool(string)

      tools = BaseAgent.list_tools(agent)
      assert length(tools) == 2
      assert calc in tools
      assert string in tools
    end

    test "creates registry on first tool registration", %{agent: agent} do
      assert agent.toolset == nil
      refute BaseAgent.has_tools?(agent)

      tool = %Calculator{}
      agent = BaseAgent.register_tool(agent, tool)

      assert agent.toolset != nil
      assert BaseAgent.has_tools?(agent)
    end
  end

  describe "BaseAgent.fetch_tool/2 and fetch_tool!/2" do
    test "retrieves registered tool", %{agent: agent} do
      tool = %Calculator{}
      agent = BaseAgent.register_tool(agent, tool)

      assert {:ok, ^tool} = BaseAgent.fetch_tool(agent, "calculator")
      assert BaseAgent.fetch_tool!(agent, "calculator") == tool
    end

    test "returns error for unregistered tool", %{agent: agent} do
      assert :error = BaseAgent.fetch_tool(agent, "nonexistent")
    end

    test "returns error when no registry exists", %{agent: agent} do
      assert agent.toolset == nil
      assert :error = BaseAgent.fetch_tool(agent, "calculator")
    end

    test "fetch_tool!/2 raises Normandy.ToolNotFoundError, with or without a toolset", %{
      agent: agent
    } do
      assert agent.toolset == nil
      assert_raise Normandy.ToolNotFoundError, fn -> BaseAgent.fetch_tool!(agent, "missing") end

      with_tool = BaseAgent.register_tool(agent, %Calculator{})

      assert_raise Normandy.ToolNotFoundError, fn ->
        BaseAgent.fetch_tool!(with_tool, "missing")
      end
    end
  end

  describe "BaseAgent.list_tools/1" do
    test "lists all registered tools", %{agent: agent} do
      calc = %Calculator{}
      string = %StringManipulator{}

      agent =
        agent
        |> BaseAgent.register_tool(calc)
        |> BaseAgent.register_tool(string)

      tools = BaseAgent.list_tools(agent)
      assert length(tools) == 2
    end

    test "returns empty list when no tools registered", %{agent: agent} do
      assert [] = BaseAgent.list_tools(agent)
    end
  end

  describe "BaseAgent.has_tools?/1" do
    test "returns false when no tools registered", %{agent: agent} do
      refute BaseAgent.has_tools?(agent)
    end

    test "returns true when tools are registered", %{agent: agent} do
      tool = %Calculator{}
      agent = BaseAgent.register_tool(agent, tool)

      assert BaseAgent.has_tools?(agent)
    end
  end

  describe "BaseAgent initialization with tool registry" do
    test "can initialize agent with pre-configured tools" do
      calc = %Calculator{}
      string = %StringManipulator{}

      registry = Toolset.new([calc, string])

      config = %{
        client: %NormandyTest.Support.ModelMockup{},
        model: "test-model",
        temperature: 0.7,
        toolset: registry
      }

      agent = BaseAgent.init(config)

      assert BaseAgent.has_tools?(agent)
      assert length(BaseAgent.list_tools(agent)) == 2
    end

    test "sets max_tool_iterations from config" do
      config = %{
        client: %NormandyTest.Support.ModelMockup{},
        model: "test-model",
        temperature: 0.7,
        max_tool_iterations: 10
      }

      agent = BaseAgent.init(config)
      assert agent.max_tool_iterations == 10
    end

    test "uses default max_tool_iterations when not specified" do
      config = %{
        client: %NormandyTest.Support.ModelMockup{},
        model: "test-model",
        temperature: 0.7
      }

      agent = BaseAgent.init(config)
      assert agent.max_tool_iterations == 20
    end
  end

  describe "register_tool/3" do
    test "forwards options to Toolset.register/3", %{agent: agent} do
      agent =
        agent
        |> BaseAgent.register_tool(%Calculator{})
        |> BaseAgent.register_tool(%Calculator{}, replace: true)

      assert Toolset.count(agent.toolset) == 1
    end

    test "an unknown option raises from Toolset.register/3", %{agent: agent} do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.register_tool(agent, %Calculator{}, timout: 5)
        end

      assert String.starts_with?(error.message, "Normandy.Tools.Toolset.register/3: ")
      assert error.message =~ ":timout"
    end
  end
end
