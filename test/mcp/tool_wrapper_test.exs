defmodule Normandy.MCP.ToolWrapperTest do
  use ExUnit.Case, async: true

  alias Normandy.MCP.ToolWrapper
  alias Normandy.Tool
  alias Normandy.Tools.Context
  alias Normandy.Tools.Toolset

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
      refute Map.has_key?(wrapper, :input)
    end

    test "creates wrapper with prefix" do
      tool = %Claudio.MCP.Client.Tool{name: "search", description: "Search", input_schema: %{}}
      wrapper = ToolWrapper.new(MockAdapter, :client, tool, prefix: "my_server")
      assert wrapper.prefix == "my_server"
    end
  end

  describe "Normandy.Tool callbacks" do
    test "tool_name without prefix", %{wrapper: wrapper} do
      assert Tool.name(wrapper) == "search"
    end

    test "tool_name with prefix" do
      tool = %Claudio.MCP.Client.Tool{name: "search", description: "Search", input_schema: %{}}
      wrapper = ToolWrapper.new(MockAdapter, :client, tool, prefix: "server1")
      assert Tool.name(wrapper) == "server1__search"
    end

    test "tool_description", %{wrapper: wrapper} do
      assert Tool.description(wrapper) == "Search the web for information"
    end

    test "tool_description falls back for nil", %{tool: tool} do
      wrapper = ToolWrapper.new(MockAdapter, :client, %{tool | description: nil})
      assert Tool.description(wrapper) == "MCP tool: search"
    end

    test "input_schema passes through", %{wrapper: wrapper} do
      schema = Tool.input_schema(wrapper)
      assert schema["type"] == "object"
      assert schema["properties"]["query"]["type"] == "string"
    end

    test "run succeeds with valid input", %{wrapper: wrapper} do
      context = %Context{tool_call_id: "t", input: %{"query" => "elixir"}}
      assert {:ok, "Results for: elixir"} = Tool.run(wrapper, context)
    end

    test "run returns error on failure" do
      tool = %Claudio.MCP.Client.Tool{
        name: "failing_tool",
        description: "Fails",
        input_schema: %{}
      }

      wrapper = ToolWrapper.new(MockAdapter, :client, tool)

      assert {:error, msg} = Tool.run(wrapper, %Context{tool_call_id: "t", input: %{}})
      assert msg =~ "MCP tool 'failing_tool' failed"
    end
  end

  describe "dispatch" do
    alias Normandy.Agents.Dispatch
    alias Normandy.Components.{ToolCall, ToolResult}

    test "the server's schema is checked before the call reaches the server", %{wrapper: wrapper} do
      config = %{name: "a", toolset: Toolset.new([wrapper])}
      call = %ToolCall{id: "m1", name: "search", input: %{"query" => "x", "bogus" => 1}}

      assert %ToolResult{is_error: true, output: %{validation_errors: [error]}} =
               Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert error.constraint == :unknown_keys
    end

    # A Claudio %MCP.Client.Tool{} the server sent no schema for has input_schema nil.
    test "a tool with no input schema answers the call with an error result", %{tool: tool} do
      wrapper = ToolWrapper.new(MockAdapter, :client, %{tool | input_schema: nil})
      config = %{name: "a", toolset: Toolset.new([wrapper])}
      call = %ToolCall{id: "m2", name: "search", input: %{"query" => "x"}}

      assert %ToolResult{is_error: true, output: %{error: error, denied: true}} =
               Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert error ==
               "invalid input for search: the tool's input_schema/1 returned nil, " <>
                 "not a JSON Schema map; the tool was not run"
    end
  end

  describe "tool registry integration" do
    test "can be registered and retrieved", %{wrapper: wrapper} do
      registry = Toolset.new([wrapper])
      assert {:ok, ^wrapper} = Toolset.fetch(registry, "search")
    end

    test "prefixed tools use prefixed name" do
      tool = %Claudio.MCP.Client.Tool{name: "search", description: "Search", input_schema: %{}}
      wrapper = ToolWrapper.new(MockAdapter, :client, tool, prefix: "s1")

      registry = Toolset.new([wrapper])
      assert {:ok, ^wrapper} = Toolset.fetch(registry, "s1__search")
    end

    test "generates tool schemas" do
      tool = %Claudio.MCP.Client.Tool{
        name: "search",
        description: "Search",
        input_schema: %{"type" => "object"}
      }

      wrapper = ToolWrapper.new(MockAdapter, :client, tool)
      registry = Toolset.new([wrapper])
      schemas = Toolset.to_tool_schemas(registry)

      assert [%{name: "search", description: "Search", input_schema: %{"type" => "object"}}] =
               schemas
    end
  end
end
