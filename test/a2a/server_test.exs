defmodule Normandy.A2A.ServerTest do
  use ExUnit.Case, async: true

  alias Normandy.A2A.Server

  describe "build_agent_card/2" do
    test "creates agent card with required fields" do
      config = build_minimal_config()

      card =
        Server.build_agent_card(config,
          name: "Test Agent",
          description: "A test agent"
        )

      assert card.name == "Test Agent"
      assert card.description == "A test agent"
    end

    test "includes version" do
      config = build_minimal_config()

      card =
        Server.build_agent_card(config,
          name: "Agent",
          description: "Desc",
          version: "1.0.0"
        )

      assert card.version == "1.0.0"
    end

    test "includes provider" do
      config = build_minimal_config()

      card =
        Server.build_agent_card(config,
          name: "Agent",
          description: "Desc",
          provider_url: "https://example.com",
          provider_org: "My Org"
        )

      assert card.provider.url == "https://example.com"
      assert card.provider.organization == "My Org"
    end

    test "includes interface from url" do
      config = build_minimal_config()

      card =
        Server.build_agent_card(config,
          name: "Agent",
          description: "Desc",
          url: "https://myapp.com/a2a"
        )

      assert length(card.supported_interfaces) == 1
      [iface] = card.supported_interfaces
      assert iface.url == "https://myapp.com/a2a"
      assert iface.protocol_binding == "jsonrpc+http"
    end

    test "adds skills from tool registry" do
      tool = %Claudio.MCP.Client.Tool{
        name: "search",
        description: "Search the web",
        input_schema: %{}
      }

      wrapper = Normandy.MCP.ToolWrapper.new(MockMCPAdapter, :client, tool)
      registry = Normandy.Tools.Registry.new([wrapper])
      config = %{build_minimal_config() | tool_registry: registry}

      card =
        Server.build_agent_card(config,
          name: "Agent",
          description: "Desc"
        )

      assert length(card.skills) == 1
      [skill] = card.skills
      assert skill.id == "search"
      assert skill.description == "Search the web"
    end
  end

  defmodule MockMCPAdapter do
    @behaviour Claudio.MCP.Client

    @impl true
    def list_tools(_client, _opts), do: {:ok, []}
    @impl true
    def call_tool(_client, _name, _args, _opts), do: {:ok, "result"}
    @impl true
    def list_resources(_client, _opts), do: {:ok, []}
    @impl true
    def read_resource(_client, _uri, _opts), do: {:ok, ""}
    @impl true
    def list_prompts(_client, _opts), do: {:ok, []}
    @impl true
    def get_prompt(_client, _name, _args, _opts), do: {:ok, ""}
    @impl true
    def ping(_client, _opts), do: :ok
  end

  defp build_minimal_config do
    alias Normandy.Components.AgentMemory

    %Normandy.Agents.BaseAgentConfig{
      input_schema: %{},
      output_schema: %{},
      client: %{},
      model: "test-model",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      temperature: 0.7,
      tool_registry: nil
    }
  end
end
