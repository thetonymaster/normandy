defmodule Normandy.MCP.ServerConfigTest do
  use ExUnit.Case, async: true

  alias Normandy.MCP.ServerConfig

  describe "new/2" do
    test "creates config with name and url" do
      config = ServerConfig.new("my_server", "https://mcp.example.com/sse")
      assert config.name == "my_server"
      assert config.url == "https://mcp.example.com/sse"
      assert config.authorization_token == nil
      assert config.tool_configuration == nil
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
    test "sets tool configuration with patterns" do
      config =
        ServerConfig.new("srv", "https://mcp.example.com")
        |> ServerConfig.allow_tools(["search_*", "fetch_data"])

      assert config.tool_configuration == %{
               "allowed_tools" => ["search_*", "fetch_data"],
               "enabled" => true
             }
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
    end

    test "converts config with auth token" do
      config =
        ServerConfig.new("srv", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("token123")

      claudio = ServerConfig.to_claudio(config)
      assert claudio.authorization_token == "token123"
    end

    test "converts config with tool configuration" do
      config =
        ServerConfig.new("srv", "https://mcp.example.com")
        |> ServerConfig.allow_tools(["search_*"])

      claudio = ServerConfig.to_claudio(config)
      assert claudio.tool_configuration == %{"allowed_tools" => ["search_*"], "enabled" => true}
    end

    test "full pipeline preserves all fields" do
      config =
        ServerConfig.new("my_server", "https://mcp.example.com/sse")
        |> ServerConfig.set_auth_token("bearer-token")
        |> ServerConfig.allow_tools(["search_*", "fetch_data"])

      claudio = ServerConfig.to_claudio(config)
      map = Claudio.MCP.ServerConfig.to_map(claudio)

      assert map["name"] == "my_server"
      assert map["url"] == "https://mcp.example.com/sse"
      assert map["type"] == "url"
      assert map["authorization_token"] == "bearer-token"
      assert map["tool_configuration"]["allowed_tools"] == ["search_*", "fetch_data"]
      assert map["tool_configuration"]["enabled"] == true
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
