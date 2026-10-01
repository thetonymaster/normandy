defmodule Normandy.MCP.ServerConfigTest do
  use ExUnit.Case, async: true

  alias Normandy.MCP.ServerConfig

  describe "new/2" do
    test "creates config with name and url" do
      config = ServerConfig.new("my_server", "https://mcp.example.com/sse")
      assert config.name == "my_server"
      assert config.url == "https://mcp.example.com/sse"
      assert config.authorization_token == nil
      assert config.allowed_tools == nil
    end
  end

  describe "set_auth_token/2" do
    test "sets the authorization token" do
      config =
        ServerConfig.new("srv", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("my-token")

      assert config.authorization_token == "my-token"
    end
  end

  describe "allow_tools/2" do
    test "stores exact tool names" do
      config =
        ServerConfig.new("srv", "https://mcp.example.com")
        |> ServerConfig.allow_tools(["search_events", "fetch_data"])

      assert config.allowed_tools == ["search_events", "fetch_data"]
    end

    test "raises at call time on a glob pattern (the connector matches names literally)" do
      config = ServerConfig.new("srv", "https://mcp.example.com")

      assert_raise ArgumentError, fn -> ServerConfig.allow_tools(config, ["search_*"]) end
      assert_raise ArgumentError, fn -> ServerConfig.allow_tools(config, ["fetch_dat?"]) end
    end
  end

  describe "to_claudio/1" do
    test "converts basic config" do
      config = ServerConfig.new("my_server", "https://mcp.example.com")
      claudio = ServerConfig.to_claudio(config)

      assert %Claudio.MCP.ServerConfig{} = claudio
      assert claudio.name == "my_server"
      assert claudio.url == "https://mcp.example.com"
      assert claudio.type == "url"
      assert claudio.default_config == nil
      assert claudio.configs == nil
    end

    test "converts config with auth token" do
      config =
        ServerConfig.new("srv", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("token123")

      claudio = ServerConfig.to_claudio(config)
      assert claudio.authorization_token == "token123"
    end

    test "applies the allowlist on Claudio's toolset (default off, named tools on)" do
      config =
        ServerConfig.new("srv", "https://mcp.example.com")
        |> ServerConfig.allow_tools(["search_events", "fetch_data"])

      claudio = ServerConfig.to_claudio(config)
      assert claudio.default_config == %{"enabled" => false}

      assert claudio.configs == %{
               "search_events" => %{"enabled" => true},
               "fetch_data" => %{"enabled" => true}
             }
    end

    test "full pipeline: server entry carries no legacy tool_configuration" do
      config =
        ServerConfig.new("my_server", "https://mcp.example.com/sse")
        |> ServerConfig.set_auth_token("bearer-token")
        |> ServerConfig.allow_tools(["search_events"])

      map = config |> ServerConfig.to_claudio() |> Claudio.MCP.ServerConfig.to_map()

      assert map["name"] == "my_server"
      assert map["url"] == "https://mcp.example.com/sse"
      assert map["type"] == "url"
      assert map["authorization_token"] == "bearer-token"
      refute Map.has_key?(map, "tool_configuration")
    end
  end

  describe "inspect" do
    test "hides authorization_token" do
      config =
        ServerConfig.new("srv", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("secret-token")

      inspected = inspect(config)
      refute inspected =~ "secret-token"
      assert inspected =~ "srv"
    end
  end
end
