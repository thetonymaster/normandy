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
    # A client of {:returns, result} answers every call with that CallToolResult.
    def call_tool({:returns, result}, _name, _args, _opts), do: {:ok, result}

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

    wrapper = ToolWrapper.new(MockAdapter, :mock_client, tool, prefix: false)
    {:ok, wrapper: wrapper, tool: tool}
  end

  describe "new/4" do
    test "creates wrapper with defaults", %{wrapper: wrapper} do
      assert wrapper.adapter == MockAdapter
      assert wrapper.client == :mock_client
      assert wrapper.tool.name == "search"
      assert wrapper.prefix == false
      refute Map.has_key?(wrapper, :input)
    end

    test "creates wrapper with prefix" do
      tool = %Claudio.MCP.Client.Tool{name: "search", description: "Search", input_schema: %{}}
      wrapper = ToolWrapper.new(MockAdapter, :client, tool, prefix: "my_server")
      assert wrapper.prefix == "my_server"
    end
  end

  describe "Normandy.Tool callbacks" do
    test "tool_name with prefix: false", %{wrapper: wrapper} do
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
      wrapper = ToolWrapper.new(MockAdapter, :client, %{tool | description: nil}, prefix: false)
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

      wrapper = ToolWrapper.new(MockAdapter, :client, tool, prefix: false)

      assert {:error, msg} = Tool.run(wrapper, %Context{tool_call_id: "t", input: %{}})
      assert msg =~ "MCP tool 'failing_tool' failed"
    end
  end

  # The shapes MCP adapters hand back (see ToolWrapper's normalize_result/1).
  defmodule ExMCPLikeResponse do
    defstruct [:content, :meta, is_error: false]
  end

  defmodule HermesLikeResponse do
    defstruct [:result, is_error: false]
  end

  describe "CallToolResult normalization (AX-14)" do
    defp run_returning(result, tool) do
      wrapper = ToolWrapper.new(MockAdapter, {:returns, result}, tool, prefix: false)
      Tool.run(wrapper, %Context{tool_call_id: "t", input: %{}})
    end

    test "text blocks become the output text; isError: true becomes {:error, text}", %{
      tool: tool
    } do
      text = fn t -> %{"type" => "text", "text" => t} end

      assert run_returning(%{"content" => [text.("a"), text.("b")], "isError" => false}, tool) ==
               {:ok, "a\nb"}

      assert run_returning(%{"content" => [text.("rate limited")], "isError" => true}, tool) ==
               {:error, "rate limited"}
    end

    test "an atom-keyed struct (ExMCP) and a wrapped result (Hermes)", %{tool: tool} do
      ex_mcp = %ExMCPLikeResponse{
        content: [
          %{type: "text", text: "hi", data: nil, annotations: nil},
          %{type: "image", text: nil, data: "iVBORw0KGgo=", annotations: nil}
        ],
        is_error: false
      }

      assert run_returning(ex_mcp, tool) == {:ok, "hi\n[image content omitted]"}

      hermes = %HermesLikeResponse{
        result: %{"content" => [%{"type" => "text", "text" => "no such city"}], "isError" => true},
        is_error: true
      }

      assert run_returning(hermes, tool) == {:error, "no such city"}
    end

    test "an error with no text still says what happened", %{tool: tool} do
      assert run_returning(%{"content" => [], "isError" => true}, tool) ==
               {:error, "The MCP tool reported an error and sent no text."}
    end

    test "a string or a map without content passes through", %{tool: tool} do
      assert run_returning("plain", tool) == {:ok, "plain"}
      assert run_returning(%{"answer" => 42}, tool) == {:ok, %{"answer" => 42}}
    end

    test "through Dispatch an MCP error is an is_error result with the bare text", %{tool: tool} do
      alias Normandy.Agents.Dispatch
      alias Normandy.Components.{BaseIOSchema, ToolCall, ToolResult}

      result = %{
        "content" => [%{"type" => "text", "text" => "quota exceeded"}],
        "isError" => true
      }

      wrapper = ToolWrapper.new(MockAdapter, {:returns, result}, tool, prefix: false)
      config = %{name: "a", toolset: Toolset.new([wrapper])}
      call = %ToolCall{id: "e1", name: "search", input: %{"query" => "x"}}

      assert %ToolResult{is_error: true, output: "quota exceeded"} =
               dispatched = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert [%{content: "quota exceeded", is_error: true}] = BaseIOSchema.to_json(dispatched)
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
      wrapper = ToolWrapper.new(MockAdapter, :client, %{tool | input_schema: nil}, prefix: false)
      config = %{name: "a", toolset: Toolset.new([wrapper])}
      call = %ToolCall{id: "m2", name: "search", input: %{"query" => "x"}}

      assert %ToolResult{is_error: true, output: %{error: error}} =
               Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert error ==
               "invalid input for search: the tool's input_schema/1 returned nil, " <>
                 "not a JSON Schema map; the tool was not run. Correct the input and call " <>
                 "the tool again."
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

      wrapper = ToolWrapper.new(MockAdapter, :client, tool, prefix: false)
      registry = Toolset.new([wrapper])
      schemas = Toolset.to_tool_schemas(registry)

      assert [%{name: "search", description: "Search", input_schema: %{"type" => "object"}}] =
               schemas
    end
  end
end
