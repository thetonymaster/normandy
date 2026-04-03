defmodule Normandy.MCP.ToolWrapperTest do
  use ExUnit.Case, async: true

  alias Normandy.MCP.ToolWrapper
  alias Normandy.Tools.BaseTool

  defmodule MockAdapter do
    @behaviour Claudio.MCP.Client

    @impl true
    def list_tools(_client, _opts), do: {:ok, []}

    @impl true
    def call_tool(_client, "search", %{"query" => query}, _opts) do
      {:ok, "Results for: #{query}"}
    end

    def call_tool(_client, "failing_tool", _args, _opts) do
      {:error, :connection_lost}
    end

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

  setup do
    tool = %Claudio.MCP.Client.Tool{
      name: "search",
      description: "Search the web for information",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query"}
        },
        "required" => ["query"]
      }
    }

    wrapper = ToolWrapper.new(MockAdapter, :mock_client, tool)
    {:ok, wrapper: wrapper, tool: tool}
  end

  describe "new/4" do
    test "creates wrapper with defaults", %{wrapper: wrapper} do
      assert wrapper.adapter == MockAdapter
      assert wrapper.client == :mock_client
      assert wrapper.tool.name == "search"
      assert wrapper.prefix == nil
      assert wrapper.input == %{}
    end

    test "creates wrapper with prefix" do
      tool = %Claudio.MCP.Client.Tool{name: "search", description: "Search", input_schema: %{}}
      wrapper = ToolWrapper.new(MockAdapter, :client, tool, prefix: "my_server")
      assert wrapper.prefix == "my_server"
    end
  end

  describe "prepare_input/2" do
    test "stores raw input map", %{wrapper: wrapper} do
      updated = ToolWrapper.prepare_input(wrapper, %{"query" => "elixir"})
      assert updated.input == %{"query" => "elixir"}
    end
  end

  describe "BaseTool protocol" do
    test "tool_name without prefix", %{wrapper: wrapper} do
      assert BaseTool.tool_name(wrapper) == "search"
    end

    test "tool_name with prefix" do
      tool = %Claudio.MCP.Client.Tool{name: "search", description: "Search", input_schema: %{}}
      wrapper = ToolWrapper.new(MockAdapter, :client, tool, prefix: "server1")
      assert BaseTool.tool_name(wrapper) == "server1__search"
    end

    test "tool_description", %{wrapper: wrapper} do
      assert BaseTool.tool_description(wrapper) == "Search the web for information"
    end

    test "tool_description falls back for nil", %{tool: tool} do
      wrapper = ToolWrapper.new(MockAdapter, :client, %{tool | description: nil})
      assert BaseTool.tool_description(wrapper) == "MCP tool: search"
    end

    test "input_schema passes through", %{wrapper: wrapper} do
      schema = BaseTool.input_schema(wrapper)
      assert schema["type"] == "object"
      assert schema["properties"]["query"]["type"] == "string"
    end

    test "run succeeds with valid input", %{wrapper: wrapper} do
      prepared = ToolWrapper.prepare_input(wrapper, %{"query" => "elixir"})
      assert {:ok, "Results for: elixir"} = BaseTool.run(prepared)
    end

    test "run returns error on failure" do
      tool = %Claudio.MCP.Client.Tool{
        name: "failing_tool",
        description: "Fails",
        input_schema: %{}
      }

      wrapper =
        ToolWrapper.new(MockAdapter, :client, tool)
        |> ToolWrapper.prepare_input(%{})

      assert {:error, msg} = BaseTool.run(wrapper)
      assert msg =~ "MCP tool 'failing_tool' failed"
    end
  end

  describe "tool registry integration" do
    test "can be registered and retrieved", %{wrapper: wrapper} do
      registry = Normandy.Tools.Registry.new([wrapper])
      assert {:ok, ^wrapper} = Normandy.Tools.Registry.get(registry, "search")
    end

    test "prefixed tools use prefixed name" do
      tool = %Claudio.MCP.Client.Tool{name: "search", description: "Search", input_schema: %{}}
      wrapper = ToolWrapper.new(MockAdapter, :client, tool, prefix: "s1")

      registry = Normandy.Tools.Registry.new([wrapper])
      assert {:ok, ^wrapper} = Normandy.Tools.Registry.get(registry, "s1__search")
    end

    test "generates tool schemas" do
      tool = %Claudio.MCP.Client.Tool{
        name: "search",
        description: "Search",
        input_schema: %{"type" => "object"}
      }

      wrapper = ToolWrapper.new(MockAdapter, :client, tool)
      registry = Normandy.Tools.Registry.new([wrapper])
      schemas = Normandy.Tools.Registry.to_tool_schemas(registry)

      assert [%{name: "search", description: "Search", input_schema: %{"type" => "object"}}] =
               schemas
    end
  end
end
