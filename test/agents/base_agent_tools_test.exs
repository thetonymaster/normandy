defmodule NormandyTest.Agents.BaseAgentToolsTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Tools.Examples.{Calculator, StringManipulator}

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
      tool = %Calculator{operation: "add", a: 1, b: 2}
      agent = BaseAgent.register_tool(agent, tool)

      assert BaseAgent.has_tools?(agent)
      assert {:ok, ^tool} = BaseAgent.get_tool(agent, "calculator")
    end

    test "registers multiple tools", %{agent: agent} do
      calc = %Calculator{operation: "add", a: 1, b: 2}
      string = %StringManipulator{operation: "uppercase", text: "hello"}

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
      assert agent.tool_registry == nil
      refute BaseAgent.has_tools?(agent)

      tool = %Calculator{operation: "add", a: 1, b: 2}
      agent = BaseAgent.register_tool(agent, tool)

      assert agent.tool_registry != nil
      assert BaseAgent.has_tools?(agent)
    end
  end

  describe "BaseAgent.get_tool/2" do
    test "retrieves registered tool", %{agent: agent} do
      tool = %Calculator{operation: "multiply", a: 3, b: 4}
      agent = BaseAgent.register_tool(agent, tool)

      assert {:ok, ^tool} = BaseAgent.get_tool(agent, "calculator")
    end

    test "returns error for unregistered tool", %{agent: agent} do
      assert :error = BaseAgent.get_tool(agent, "nonexistent")
    end

    test "returns error when no registry exists", %{agent: agent} do
      assert agent.tool_registry == nil
      assert :error = BaseAgent.get_tool(agent, "calculator")
    end
  end

  describe "BaseAgent.list_tools/1" do
    test "lists all registered tools", %{agent: agent} do
      calc = %Calculator{operation: "add", a: 1, b: 2}
      string = %StringManipulator{operation: "uppercase", text: "test"}

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
      tool = %Calculator{operation: "add", a: 1, b: 2}
      agent = BaseAgent.register_tool(agent, tool)

      assert BaseAgent.has_tools?(agent)
    end
  end

  describe "BaseAgent initialization with tool registry" do
    test "can initialize agent with pre-configured tools" do
      calc = %Calculator{operation: "add", a: 1, b: 2}
      string = %StringManipulator{operation: "uppercase", text: "test"}

      registry = Normandy.Tools.Registry.new([calc, string])

      config = %{
        client: %NormandyTest.Support.ModelMockup{},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry
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
      assert agent.max_tool_iterations == 5
    end
  end
end
