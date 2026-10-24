defmodule Normandy.Agents.Turn.ServerPausedThinkingTest do
  @moduledoc """
  Final review M2 (a7f5621): a paused turn whose blocks are `[thinking, mcp_tool_use]`,
  stamped with the current prefix key (same model, prompt and tools, so its thinking is
  not stale), is trimmed to `[thinking]` once it is no longer the last message (the use
  has no result in memory: the continuation is stored as its answer only). A message
  left with only thinking is dropped, so the next request carries neither a
  thinking-only assistant message nor the unanswered server-tool use.
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

  @thinking_types ["thinking", "redacted_thinking"]
  @server_use_types ["server_tool_use", "mcp_tool_use"]

  test "a trimmed paused turn left with only thinking never reaches the next request" do
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

    # The new input: the paused message is no longer last, so its unanswered use is
    # trimmed, and what is left (only thinking) is dropped.
    assert {:ok, %BaseAgentOutputSchema{chat_message: "Answer two."}} =
             Turn.Server.run(srv, "q2")

    assert_received {:wire_body, 2, body}
    messages = body["messages"]

    assistant_blocks =
      for %{"role" => "assistant", "content" => content} <- messages, do: blocks(content)

    refute Enum.any?(assistant_blocks, fn blocks ->
             blocks != [] and Enum.all?(blocks, &(&1["type"] in @thinking_types))
           end),
           "an assistant message holds only thinking: #{inspect(messages)}"

    all_blocks = Enum.flat_map(messages, &blocks(&1["content"]))
    refute Enum.any?(all_blocks, &(&1["type"] in @server_use_types))
    refute Enum.any?(all_blocks, &(&1["type"] in @thinking_types))

    assert %{"role" => "user", "content" => q2} = List.last(messages)
    assert inspect(q2) =~ "q2"
    assert inspect(messages) =~ "Found it."
  end

  defp blocks(content) when is_list(content), do: content
  defp blocks(_text), do: []
end
