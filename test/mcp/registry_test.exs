defmodule Normandy.MCP.RegistryTest do
  use ExUnit.Case, async: true

  alias Normandy.MCP.Registry, as: MCPRegistry
  alias Normandy.MCP.ToolWrapper
  alias Normandy.Tools.Toolset

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
      registry = Toolset.new()

      assert {:ok, updated} =
               MCPRegistry.discover_and_register(registry, MockAdapter, :client, prefix: false)

      assert Toolset.count(updated) == 2
      assert Toolset.has_tool?(updated, "search")
      assert Toolset.has_tool?(updated, "fetch")
    end

    test "applies prefix to tool names" do
      registry = Toolset.new()

      assert {:ok, updated} =
               MCPRegistry.discover_and_register(registry, MockAdapter, :client, prefix: "srv")

      assert Toolset.has_tool?(updated, "srv__search")
      assert Toolset.has_tool?(updated, "srv__fetch")
    end

    test "preserves existing tools in registry" do
      tool = %Claudio.MCP.Client.Tool{name: "existing", description: "Pre", input_schema: %{}}

      existing_wrapper = ToolWrapper.new(MockAdapter, :client, tool, prefix: false)
      registry = Toolset.new([existing_wrapper])

      assert {:ok, updated} =
               MCPRegistry.discover_and_register(registry, MockAdapter, :client, prefix: false)

      assert Toolset.count(updated) == 3
      assert Toolset.has_tool?(updated, "existing")
    end

    test "returns error when discovery fails" do
      registry = Toolset.new()

      assert {:error, :connection_refused} =
               MCPRegistry.discover_and_register(registry, FailingAdapter, :client, prefix: false)
    end
  end

  describe "wrap_tools/4" do
    test "wraps a list of tools" do
      tools = [
        %Claudio.MCP.Client.Tool{name: "a", description: "Tool A", input_schema: %{}},
        %Claudio.MCP.Client.Tool{name: "b", description: "Tool B", input_schema: %{}}
      ]

      wrappers = MCPRegistry.wrap_tools(MockAdapter, :client, tools, prefix: false)
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
    test "two tools with the same name raise instead of one silently winning" do
      tool_a = %Claudio.MCP.Client.Tool{name: "search", description: "A", input_schema: %{}}
      tool_b = %Claudio.MCP.Client.Tool{name: "search", description: "B", input_schema: %{}}

      wrapper_a = ToolWrapper.new(MockAdapter, :client, tool_a, prefix: false)
      wrapper_b = ToolWrapper.new(MockAdapter, :client, tool_b, prefix: false)

      assert_raise ArgumentError, ~r/"search" is already registered/, fn ->
        Toolset.new([wrapper_a, wrapper_b])
      end
    end

    test "discovering a server whose tool names are taken returns an error" do
      {:ok, registry} =
        MCPRegistry.discover_and_register(Toolset.new(), MockAdapter, :client, prefix: false)

      assert {:error, {:tool_name_taken, "search"}} =
               MCPRegistry.discover_and_register(registry, MockAdapter, :client, prefix: false)
    end

    test "a tool name the API would refuse is an error, not a raise" do
      defmodule DottedAdapter do
        def list_tools(_client, _opts),
          do: {:ok, [%Claudio.MCP.Client.Tool{name: "files.read", input_schema: %{}}]}
      end

      assert {:error, {:invalid_tool_name, "files.read"}} =
               MCPRegistry.discover_and_register(Toolset.new(), DottedAdapter, :client,
                 prefix: false
               )
    end

    test "prefix avoids name collisions" do
      tool = %Claudio.MCP.Client.Tool{name: "search", description: "Search", input_schema: %{}}
      wrapper_a = ToolWrapper.new(MockAdapter, :client, tool, prefix: "server1")
      wrapper_b = ToolWrapper.new(MockAdapter, :client, tool, prefix: "server2")

      registry = Toolset.new([wrapper_a, wrapper_b])
      assert Toolset.count(registry) == 2
      assert Toolset.has_tool?(registry, "server1__search")
      assert Toolset.has_tool?(registry, "server2__search")
    end
  end
end
