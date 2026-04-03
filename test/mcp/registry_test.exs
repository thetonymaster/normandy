defmodule Normandy.MCP.RegistryTest do
  use ExUnit.Case, async: true

  alias Normandy.MCP.Registry, as: MCPRegistry
  alias Normandy.Tools.Registry

  defmodule MockAdapter do
    @behaviour Claudio.MCP.Client

    @impl true
    def list_tools(_client, _opts) do
      {:ok,
       [
         %Claudio.MCP.Client.Tool{
           name: "search",
           description: "Search the web",
           input_schema: %{"type" => "object"}
         },
         %Claudio.MCP.Client.Tool{
           name: "fetch",
           description: "Fetch a URL",
           input_schema: %{"type" => "object"}
         }
       ]}
    end

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

  defmodule FailingAdapter do
    @behaviour Claudio.MCP.Client

    @impl true
    def list_tools(_client, _opts), do: {:error, :connection_refused}
    @impl true
    def call_tool(_client, _name, _args, _opts), do: {:error, :connection_refused}
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

  describe "discover_and_register/4" do
    test "discovers and registers all tools" do
      registry = Registry.new()
      assert {:ok, updated} = MCPRegistry.discover_and_register(registry, MockAdapter, :client)

      assert Registry.count(updated) == 2
      assert Registry.has_tool?(updated, "search")
      assert Registry.has_tool?(updated, "fetch")
    end

    test "applies prefix to tool names" do
      registry = Registry.new()

      assert {:ok, updated} =
               MCPRegistry.discover_and_register(registry, MockAdapter, :client, prefix: "srv")

      assert Registry.has_tool?(updated, "srv__search")
      assert Registry.has_tool?(updated, "srv__fetch")
    end

    test "preserves existing tools in registry" do
      tool = %Claudio.MCP.Client.Tool{name: "existing", description: "Pre", input_schema: %{}}

      existing_wrapper = Normandy.MCP.ToolWrapper.new(MockAdapter, :client, tool)
      registry = Registry.new([existing_wrapper])

      assert {:ok, updated} = MCPRegistry.discover_and_register(registry, MockAdapter, :client)
      assert Registry.count(updated) == 3
      assert Registry.has_tool?(updated, "existing")
    end

    test "returns error when discovery fails" do
      registry = Registry.new()

      assert {:error, :connection_refused} =
               MCPRegistry.discover_and_register(registry, FailingAdapter, :client)
    end
  end

  describe "wrap_tools/4" do
    test "wraps a list of tools" do
      tools = [
        %Claudio.MCP.Client.Tool{name: "a", description: "Tool A", input_schema: %{}},
        %Claudio.MCP.Client.Tool{name: "b", description: "Tool B", input_schema: %{}}
      ]

      wrappers = MCPRegistry.wrap_tools(MockAdapter, :client, tools)
      assert length(wrappers) == 2
      assert Enum.all?(wrappers, &match?(%Normandy.MCP.ToolWrapper{}, &1))
    end

    test "applies prefix to wrapped tools" do
      tools = [%Claudio.MCP.Client.Tool{name: "a", description: "Tool A", input_schema: %{}}]

      [wrapper] = MCPRegistry.wrap_tools(MockAdapter, :client, tools, prefix: "ns")
      assert wrapper.prefix == "ns"
    end
  end

  describe "name collision behavior" do
    test "later tool with same name overwrites earlier one" do
      tool_a = %Claudio.MCP.Client.Tool{name: "search", description: "A", input_schema: %{}}
      tool_b = %Claudio.MCP.Client.Tool{name: "search", description: "B", input_schema: %{}}

      wrapper_a = Normandy.MCP.ToolWrapper.new(MockAdapter, :client, tool_a)
      wrapper_b = Normandy.MCP.ToolWrapper.new(MockAdapter, :client, tool_b)

      registry = Registry.new([wrapper_a, wrapper_b])
      assert Registry.count(registry) == 1

      {:ok, tool} = Registry.get(registry, "search")
      assert Normandy.Tools.BaseTool.tool_description(tool) == "B"
    end

    test "prefix avoids name collisions" do
      tool = %Claudio.MCP.Client.Tool{name: "search", description: "Search", input_schema: %{}}
      wrapper_a = Normandy.MCP.ToolWrapper.new(MockAdapter, :client, tool, prefix: "server1")
      wrapper_b = Normandy.MCP.ToolWrapper.new(MockAdapter, :client, tool, prefix: "server2")

      registry = Registry.new([wrapper_a, wrapper_b])
      assert Registry.count(registry) == 2
      assert Registry.has_tool?(registry, "server1__search")
      assert Registry.has_tool?(registry, "server2__search")
    end
  end
end
