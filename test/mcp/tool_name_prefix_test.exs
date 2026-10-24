defmodule Normandy.MCP.ToolNamePrefixTest do
  # SEC-2: a remote server or agent chooses its tool names, so every entry point that
  # wraps remote tools takes a required :prefix the host chooses.
  use ExUnit.Case, async: true

  alias Claudio.A2A.AgentCard
  alias Normandy.A2A.AgentTool
  alias Normandy.A2A.Registry, as: A2ARegistry
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Behaviours.PolicyEngine.Ruleset
  alias Normandy.Components.ToolCall
  alias Normandy.MCP.Registry, as: MCPRegistry
  alias Normandy.MCP.ToolWrapper
  alias Normandy.Tool
  alias Normandy.Tools.Toolset

  defmodule PurgeServer do
    @moduledoc false
    def list_tools(_client, _opts),
      do: {:ok, [%Claudio.MCP.Client.Tool{name: "read_and_purge", input_schema: %{}}]}
  end

  @tool %Claudio.MCP.Client.Tool{name: "read_and_purge", input_schema: %{}}

  describe ":prefix is required" do
    test "on every MCP entry point, named in the error" do
      calls = [
        {"Normandy.MCP.ToolWrapper.new/4", fn -> ToolWrapper.new(PurgeServer, nil, @tool) end},
        {"Normandy.MCP.Registry.discover_and_register/4",
         fn -> MCPRegistry.discover_and_register(Toolset.new(), PurgeServer, nil) end},
        {"Normandy.MCP.Registry.wrap_tools/4",
         fn -> MCPRegistry.wrap_tools(PurgeServer, nil, [@tool]) end},
        {"Normandy.Agents.BaseAgent.register_mcp_tools/4",
         fn -> BaseAgent.register_mcp_tools(%BaseAgentConfig{}, PurgeServer, nil) end}
      ]

      for {mfa, call} <- calls do
        error = assert_raise ArgumentError, call

        assert error.message ==
                 "#{mfa}: required :prefix option not found, received options: []"
      end
    end

    test "on every A2A entry point, named in the error" do
      card = AgentCard.new("Agent", "An agent")

      calls = [
        {"Normandy.A2A.AgentTool.new/3", fn -> AgentTool.new("http://a", card) end},
        {"Normandy.A2A.Registry.from_agent_card/3",
         fn -> A2ARegistry.from_agent_card(card, "http://a") end},
        {"Normandy.A2A.Registry.discover_and_register/3",
         fn -> A2ARegistry.discover_and_register(Toolset.new(), "http://a") end}
      ]

      for {mfa, call} <- calls do
        error = assert_raise ArgumentError, call
        assert error.message =~ "#{mfa}: required :prefix option not found"
      end
    end

    test "a ToolWrapper struct literal without :prefix does not compile" do
      assert_raise ArgumentError, ~r/must also be given.*:prefix/, fn ->
        Code.eval_string("%Normandy.MCP.ToolWrapper{adapter: nil, client: nil, tool: nil}")
      end
    end
  end

  describe "the prefix rule" do
    test "a prefix whose __ would be ambiguous is refused" do
      for bad <- ["a_", "_a", "a__b", "", "a.b", String.duplicate("a", 62)] do
        error =
          assert_raise ArgumentError, fn ->
            ToolWrapper.new(PurgeServer, nil, @tool, prefix: bad)
          end

        assert error.message =~
                 "Normandy.MCP.ToolWrapper.new/4: invalid value for :prefix option: expected " <>
                   "false or a prefix of letters, digits, - and single _ (no __, no _ at " <>
                   "either end), at most 61 bytes"
      end
    end

    test "letters, digits, - and single _ are accepted, up to 61 bytes" do
      for good <- ["srv", "my_server", "a-b_c9", String.duplicate("a", 61)] do
        assert Tool.name(ToolWrapper.new(PurgeServer, nil, @tool, prefix: good)) ==
                 good <> "__read_and_purge"
      end
    end

    test "prefix: false keeps the server's name" do
      assert Tool.name(ToolWrapper.new(PurgeServer, nil, @tool, prefix: false)) ==
               "read_and_purge"
    end

    test "true and nil are not prefixes" do
      for bad <- [true, nil] do
        assert_raise ArgumentError, ~r/invalid value for :prefix option/, fn ->
          ToolWrapper.new(PurgeServer, nil, @tool, prefix: bad)
        end
      end
    end

    test "A2A tools take the same rule; \"a2a\" gives 1.x's names" do
      card = AgentCard.new("Research Agent", "r") |> AgentCard.add_skill("web search", "s")

      assert_raise ArgumentError, ~r/AgentTool.new\/3: invalid value for :prefix option/, fn ->
        AgentTool.new("http://a", card, prefix: "a_")
      end

      assert Tool.name(AgentTool.new("http://a", card, prefix: "a2a")) == "a2a__research_agent"

      assert Tool.name(AgentTool.new("http://a", card, prefix: "res", skill_id: "web search")) ==
               "res__research_agent__web_search"

      assert Tool.name(AgentTool.new("http://a", card, prefix: false)) == "research_agent"
    end
  end

  describe "a server-chosen name no longer matches the host's rule (SEC-2)" do
    @policy [
      rules: [%{match: "read_*", action: :allow}],
      default_action: :require_approval
    ]

    test "read_and_purge from server srv needs approval" do
      {:ok, toolset} =
        MCPRegistry.discover_and_register(Toolset.new(), PurgeServer, nil, prefix: "srv")

      assert Toolset.list_names(toolset) == ["srv__read_and_purge"]

      call = %ToolCall{id: "c1", name: "srv__read_and_purge", input: %{}}
      assert {:needs_approval, _meta} = Ruleset.check(call, %{opts: @policy})
    end

    test "a rule on the prefix matches exactly that server's tools" do
      opts = [rules: [%{match: "srv__*", action: :deny}], default_action: :allow]

      assert {:deny, _} = Ruleset.check(%ToolCall{name: "srv__read_and_purge"}, %{opts: opts})
      assert {:allow, _} = Ruleset.check(%ToolCall{name: "srv2__read_and_purge"}, %{opts: opts})
    end
  end
end
