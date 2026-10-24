defmodule Normandy.Agents.AssistantTurnReplayTest do
  @moduledoc """
  Task 5.3b (AX-7, Review Focus #3): an assistant turn that mixes thinking, text with
  citations, a client `tool_use`, a `server_tool_use` and an `mcp_tool_use` goes back
  on the next request as `Claudio.Messages.Response.to_assistant_content/1` makes it,
  on `run/3`, `stream/3` and under `Turn.Server`, and the MCP call is not run locally.
  An earlier chat answer goes back as its plain text (AX-21).
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Claudio.Messages.Response, as: ClaudioResponse
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.FakeTool
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  @citation %{
    "type" => "web_search_result_location",
    "url" => "https://example.com/paris",
    "title" => "Paris",
    "encrypted_index" => "eidx",
    "cited_text" => "Paris is sunny."
  }
  @thinking %{"type" => "thinking", "thinking" => "look it up", "signature" => "sig1"}
  @cited %{"type" => "text", "text" => "Paris is sunny.", "citations" => [@citation]}
  @server_use %{
    "type" => "server_tool_use",
    "id" => "srvtoolu_1",
    "name" => "web_search",
    "input" => %{"query" => "paris weather"}
  }
  @search_result %{
    "type" => "web_search_tool_result",
    "tool_use_id" => "srvtoolu_1",
    "content" => [
      %{
        "type" => "web_search_result",
        "url" => "https://example.com/paris",
        "title" => "Paris",
        "encrypted_content" => "enc"
      }
    ]
  }
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
  @more %{"type" => "text", "text" => "Checking the local tool."}
  @tool_use %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}
  @turn [@thinking, @cited, @server_use, @search_result, @mcp_use, @mcp_result, @more, @tool_use]
  @done %{"type" => "text", "text" => "Done."}

  # The oracle: what Claudio's canonical replay makes of the response.
  defp expected_replay,
    do:
      %{"content" => @turn}
      |> ClaudioResponse.from_map()
      |> ClaudioResponse.to_assistant_content()

  defp agent(client) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      toolset:
        Toolset.new([
          %FakeTool{notify: self()},
          %FakeTool{name: "docs__search", notify: self()}
        ])
    })
  end

  defp replayed_assistant(n) do
    assert_received {:wire_body, ^n, body}

    assert [_user, %{"role" => "assistant", "content" => content}, %{"role" => "user"}] =
             body["messages"]

    content
  end

  defp assert_replayed_as_received do
    content = replayed_assistant(1)
    assert content == expected_replay()
    # Claudio 0.7.1 replays a text block's citations (Task 7.5b, decision 27 B3): the
    # cited block goes back exactly as the API returned it.
    assert Enum.at(content, 1) == @cited
    assert_received {:tool_ran, "weather"}
    refute_received {:tool_ran, "docs__search"}
  end

  # The same turn, streamed: thinking and signature deltas, a citations delta, and
  # the server and MCP tool inputs as input_json_delta.
  defp streamed_turn do
    blocks = [
      {%{"type" => "thinking", "thinking" => ""},
       [
         %{"type" => "thinking_delta", "thinking" => "look it up"},
         %{"type" => "signature_delta", "signature" => "sig1"}
       ]},
      {%{"type" => "text", "text" => ""},
       [
         %{"type" => "citations_delta", "citation" => @citation},
         %{"type" => "text_delta", "text" => "Paris is sunny."}
       ]},
      {%{@server_use | "input" => %{}},
       [%{"type" => "input_json_delta", "partial_json" => ~s({"query": "paris weather"})}]},
      {@search_result, []},
      {%{@mcp_use | "input" => %{}},
       [%{"type" => "input_json_delta", "partial_json" => ~s({"q": "paris"})}]},
      {@mcp_result, []},
      {%{"type" => "text", "text" => ""},
       [%{"type" => "text_delta", "text" => "Checking the local tool."}]},
      {@tool_use, [%{"type" => "input_json_delta", "partial_json" => "{}"}]}
    ]

    events =
      blocks
      |> Enum.with_index()
      |> Enum.flat_map(fn {{start, deltas}, index} -> WireScript.block(index, start, deltas) end)

    WireScript.message("msg_0", events, "tool_use")
  end

  defp streamed_done do
    WireScript.message(
      "msg_1",
      WireScript.block(0, %{"type" => "text", "text" => ""}, [
        %{"type" => "text_delta", "text" => "Done."}
      ]),
      "end_turn"
    )
  end

  test "run/3 replays the turn as received" do
    client = WireScript.client([{:json, @turn, "tool_use"}, {:json, [@done], "end_turn"}])

    assert {:ok, _config, %{chat_message: "Done."}} = BaseAgent.run(agent(client), "weather?")
    assert_replayed_as_received()
  end

  test "stream/3 replays the streamed turn in the same shape" do
    client = WireScript.client([{:sse, streamed_turn()}, {:sse, streamed_done()}])

    assert {:ok, _config, %{chat_message: "Done."}} =
             BaseAgent.stream(agent(client), "weather?", fn _ -> :ok end)

    assert_replayed_as_received()
  end

  test "Turn.Server replays the turn as received" do
    client = WireScript.client([{:json, @turn, "tool_use"}, {:json, [@done], "end_turn"}])

    {:ok, srv} =
      Server.start_link(
        session_id: "s-replay",
        config: agent(client),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:ok, %{chat_message: "Done."}} = Server.run(srv, "weather?")
    assert_replayed_as_received()
  end

  test "an earlier chat answer goes back as its plain text" do
    client =
      WireScript.client([
        {:json, [@done], "end_turn"},
        {:json, [%{"type" => "text", "text" => "Again."}], "end_turn"}
      ])

    {:ok, config, _} = BaseAgent.run(agent(client), "first")
    {:ok, _config, _} = BaseAgent.run(config, "second")

    assert_received {:wire_body, 1, body}

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "content" => "Done."},
             %{"role" => "user"}
           ] = body["messages"]
  end
end
