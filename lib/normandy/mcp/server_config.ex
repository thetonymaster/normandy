defmodule Normandy.MCP.ServerConfig do
  @moduledoc """
  Configuration for server-side MCP servers passed to the Anthropic API.

  When using server-side MCP, Claude connects to the MCP server directly.
  This is simpler than client-side MCP but requires the server to be
  accessible from Anthropic's infrastructure.

  ## Example

      alias Normandy.MCP.ServerConfig

      server = ServerConfig.new("my_server", "https://mcp.example.com/sse")
      |> ServerConfig.set_auth_token("bearer-token")
      |> ServerConfig.allow_tools(["search_events", "fetch_data"])

      agent = BaseAgent.add_mcp_server(agent, server)

  """

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          authorization_token: String.t() | nil,
          allowed_tools: [String.t()] | nil
        }

  @derive {Inspect, except: [:authorization_token]}
  defstruct [:name, :url, :authorization_token, :allowed_tools]

  @doc """
  Creates a new MCP server configuration.
  """
  @spec new(String.t(), String.t()) :: t()
  def new(name, url) when is_binary(name) and is_binary(url) do
    %__MODULE__{name: name, url: url}
  end

  @doc """
  Sets the authorization token for the MCP server.
  """
  @spec set_auth_token(t(), String.t()) :: t()
  def set_auth_token(%__MODULE__{} = config, token) when is_binary(token) do
    %{config | authorization_token: token}
  end

  @doc """
  Allowlists tools from this MCP server by **exact name**; every other tool is
  disabled. A later call replaces the allowlist.

  Raises `ArgumentError` on a name containing `*` or `?`: the connector matches
  names literally, so a pattern would enable no tools at all.
  """
  @spec allow_tools(t(), [String.t()]) :: t()
  def allow_tools(%__MODULE__{} = config, names) when is_list(names) do
    # Validate now, where the mistake is, rather than when the request is built.
    _ =
      Claudio.MCP.ServerConfig.allow_tools(
        Claudio.MCP.ServerConfig.new(config.name, config.url),
        names
      )

    %{config | allowed_tools: names}
  end

  @doc """
  Converts to a `Claudio.MCP.ServerConfig` struct for API serialization.
  """
  @spec to_claudio(t()) :: Claudio.MCP.ServerConfig.t()
  def to_claudio(%__MODULE__{} = config) do
    claudio_config = Claudio.MCP.ServerConfig.new(config.name, config.url)

    claudio_config =
      if config.authorization_token do
        Claudio.MCP.ServerConfig.set_auth_token(claudio_config, config.authorization_token)
      else
        claudio_config
      end

    if config.allowed_tools do
      Claudio.MCP.ServerConfig.allow_tools(claudio_config, config.allowed_tools)
    else
      claudio_config
    end
  end
end
