defmodule Normandy.Agents.Turn.ServerPausedThinkingTest do
  @moduledoc """
  Final review M2 (a7f5621), revised when the continuation's tool result began to be
  stored: a paused turn whose blocks are `[thinking, mcp_tool_use]`, stamped with the
  current prefix key (same model, prompt and tools, so its thinking is not stale), is
  followed in memory by the continuation's `mcp_tool_result`, so the use is answered and
  the paused turn reaches the next request whole. The continuation goes whole too (its
  text beside the answer): the thinking before it in the same wire turn is signed.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.MCP.ServerConfig
  alias Normandy.Test.WireScript

  @thinking %{"type" => "thinking", "thinking" => "search the docs", "signature" => "sig1"}
  @mcp_use %{
    "type" => "mcp_tool_use",
    "id" => "mcptoolu_1",
    "name" => "search",
    "server_name" => "docs",
    "input" => %{"q" => "paris"}
  }
  @mcp_result %{
    "type" => "mcp_tool_result",
    "tool_use_id" => "mcptoolu_1",
    "server_name" => "docs",
    "is_error" => false,
    "content" => [%{"type" => "text", "text" => "found"}]
  }
  @found %{"type" => "text", "text" => "Found it."}
  @answer_two %{"type" => "text", "text" => "Answer two."}

  test "a paused turn with thinking reaches the next request whole once its result is stored" do
    client =
      WireScript.client(
        [
          {:json, [@thinking, @mcp_use], "pause_turn"},
          {:json, [@mcp_result, @found], "end_turn"},
          {:json, [@answer_two], "end_turn"}
        ],
        %{thinking: :adaptive}
      )

    config =
      BaseAgent.init(%{
        client: client,
        model: "claude-opus-5-5",
        mcp_servers: [ServerConfig.new("docs", "https://mcp.example.com/sse")]
      })

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "paused-thinking-#{System.unique_integer([:positive])}",
        config: config,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    # q1 pauses with [thinking, mcp_tool_use]; the continuation (the paused turn sent
    # back as the last message, thinking and use intact) answers.
    assert {:ok, %BaseAgentOutputSchema{chat_message: "Found it."}} =
             Turn.Server.run(srv, "q1")

    assert_received {:wire_body, 1, continuation}

    assert %{"role" => "assistant", "content" => [@thinking, @mcp_use]} =
             List.last(continuation["messages"])

    # The new input: the paused message is no longer last, and its use is answered by
    # the stored continuation, so both go as they came.
    assert {:ok, %BaseAgentOutputSchema{chat_message: "Answer two."}} =
             Turn.Server.run(srv, "q2")

    assert_received {:wire_body, 2, body}
    messages = body["messages"]

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "content" => [@thinking, @mcp_use]},
             %{
               "role" => "assistant",
               "content" => [
                 %{"type" => "mcp_tool_result", "tool_use_id" => "mcptoolu_1"},
                 @found
               ]
             },
             %{"role" => "assistant"},
             %{"role" => "user"}
           ] = messages

    assert %{"role" => "user", "content" => q2} = List.last(messages)
    assert inspect(q2) =~ "q2"
    assert inspect(messages) =~ "Found it."
  end
end
