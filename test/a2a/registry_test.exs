defmodule Normandy.A2A.RegistryTest do
  use ExUnit.Case, async: true

  alias Claudio.A2A.AgentCard
  alias Normandy.A2A.Registry, as: A2ARegistry
  alias Normandy.Tools.Toolset

  defmodule LongNameTransport do
    def discover(_url, _opts),
      do: {:ok, AgentCard.new(String.duplicate("very long agent name ", 4), "An agent")}
  end

  defmodule OkTransport do
    def discover(_url, _opts), do: {:ok, AgentCard.new("Agent", "An agent")}
  end

  describe "discover_and_register/3" do
    test "an agent whose tool name the API would refuse is an error, not a raise" do
      assert {:error, {:invalid_tool_name, name}} =
               A2ARegistry.discover_and_register(Toolset.new(), "http://agent.test",
                 prefix: "a2a",
                 transport_opts: [transport: LongNameTransport]
               )

      assert String.length(name) > 64
    end

    test ":timeout is each tool's registration timeout; 60 s when not given" do
      opts = [prefix: "a2a", transport_opts: [transport: OkTransport]]

      assert {:ok, toolset} =
               A2ARegistry.discover_and_register(
                 Toolset.new(),
                 "http://agent.test",
                 [timeout: 5_000] ++ opts
               )

      assert Toolset.timeout(toolset, "a2a__agent") == 5_000

      assert {:ok, toolset} =
               A2ARegistry.discover_and_register(Toolset.new(), "http://agent.test", opts)

      assert Toolset.timeout(toolset, "a2a__agent") == 60_000
    end
  end

  describe "from_agent_card/3" do
    test "creates single tool for agent with no skills" do
      card = AgentCard.new("Agent", "A simple agent")
      tools = A2ARegistry.from_agent_card(card, "https://example.com/a2a", prefix: "a2a")

      assert length(tools) == 1
      [tool] = tools
      assert tool.endpoint == "https://example.com/a2a"
      assert tool.skill_id == nil
    end

    test "creates one tool per skill" do
      card =
        AgentCard.new("Agent", "Multi-skill agent")
        |> AgentCard.add_skill("search", "Search the web")
        |> AgentCard.add_skill("summarize", "Summarize text")

      tools = A2ARegistry.from_agent_card(card, "https://example.com/a2a", prefix: "a2a")

      assert length(tools) == 2
      skill_ids = Enum.map(tools, & &1.skill_id)
      assert "search" in skill_ids
      assert "summarize" in skill_ids
    end

    test "passes options through" do
      card = AgentCard.new("Agent", "An agent")

      tools =
        A2ARegistry.from_agent_card(card, "https://example.com/a2a",
          prefix: "a2a",
          auth_token: "tok"
        )

      [tool] = tools
      assert tool.auth_token == "tok"
    end
  end

  describe "from_agent_card registry integration" do
    test "tools can be registered" do
      card =
        AgentCard.new("My Agent", "Does things")
        |> AgentCard.add_skill("search", "Search")

      tools = A2ARegistry.from_agent_card(card, "https://example.com/a2a", prefix: "a2a")
      registry = Toolset.new(tools)

      assert Toolset.count(registry) == 1
      assert Toolset.has_tool?(registry, "a2a__my_agent__search")
    end
  end
end
