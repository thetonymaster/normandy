defmodule Normandy.LLM.ClaudioAdapterRequestParityTest do
  @moduledoc """
  Every call path (legacy, structured, raw retry, streaming) builds its request
  the same way, so a setting reaches the API whichever path a call takes.
  """
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.Agents.Model
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.MCP.ServerConfig

  @messages [%Message{role: "user", content: "hi"}]

  defp capture_body(name) do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 500, "")
    end)
  end

  defp client(name),
    do: %ClaudioAdapter{
      api_key: "k",
      options: %{req_options: [plug: {Req.Test, name}, retry: false]}
    }

  test "streaming sends the MCP servers too" do
    capture_body(__MODULE__.Stream)
    servers = [ServerConfig.new("docs", "https://mcp.example.com/sse")]

    _ =
      Model.stream(
        client(__MODULE__.Stream),
        %Normandy.LLM.Request{
          model: "claude-opus-5-5",
          max_tokens: 1024,
          messages: @messages,
          mcp_servers: servers
        },
        []
      )

    assert_received {:body, body}
    assert [%{"name" => "docs", "url" => "https://mcp.example.com/sse"}] = body["mcp_servers"]
  end

  describe "messages the adapter cannot send" do
    @impl_module Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter

    defp add(messages),
      do: @impl_module.add_messages(Request.new("m"), messages, false)

    test "an entry that is not a %Message{} raises instead of being dropped" do
      assert_raise ArgumentError, ~r/expected a %Normandy.Components.Message{}, got a map/, fn ->
        add([%{role: "user", content: "hi"}])
      end
    end

    test "a message without a role raises instead of being dropped" do
      assert_raise ArgumentError, ~r/message role must be a string, got: nil/, fn ->
        add([%Message{role: nil, content: "hi"}])
      end
    end
  end
end
