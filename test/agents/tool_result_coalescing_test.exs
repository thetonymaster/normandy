defmodule Normandy.Agents.ToolResultCoalescingTest do
  @moduledoc """
  Task 5.3a. AX-6: a batch of tool results goes to the model as one user message, on
  `run/3`, `stream/3` and under `Turn.Server`, while memory and the store keep one
  entry per result. AX-3: `mcp_tool_use` and `server_tool_use` blocks, which the API
  ran, are never dispatched as local tools.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.Components.ToolCall
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Test.FakeTool
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  @weather %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}
  @clock %{"type" => "tool_use", "id" => "t2", "name" => "clock", "input" => %{}}
  @done %{"type" => "text", "text" => "Done."}

  defp agent(client, tools \\ [%FakeTool{}, %FakeTool{name: "clock"}]) do
    BaseAgent.init(%{client: client, model: "claude-opus-5-5", toolset: Toolset.new(tools)})
  end

  defp server(config, session_id, store) do
    {:ok, srv} =
      Server.start_link(
        session_id: session_id,
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()}
      )

    srv
  end

  defp streamed(id, tool_uses, stop) do
    blocks =
      tool_uses
      |> Enum.with_index()
      |> Enum.flat_map(fn {tool_use, index} ->
        WireScript.block(index, Map.put(tool_use, "input", %{}), [
          %{"type" => "input_json_delta", "partial_json" => "{}"}
        ])
      end)

    WireScript.message(id, blocks, stop)
  end

  defp streamed_text(id, text) do
    WireScript.message(
      id,
      WireScript.block(0, %{"type" => "text", "text" => ""}, [
        %{"type" => "text_delta", "text" => text}
      ]),
      "end_turn"
    )
  end

  # The second request: the user turn, the assistant's two calls, then ONE user
  # message with both results in tool_use order.
  defp assert_one_result_message do
    assert_received {:wire_body, 1, body}
    assert Enum.map(body["messages"], & &1["role"]) == ["user", "assistant", "user"]

    assert [
             %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "weather in "},
             %{"type" => "tool_result", "tool_use_id" => "t2", "content" => "weather in "}
           ] = List.last(body["messages"])["content"]
  end

  describe "AgentMemory.request_messages/1" do
    test "merges each run of tool messages into one, blocks in order" do
      history = [
        %{role: "user", content: "q"},
        %{role: "assistant", content: [%{type: "tool_use", id: "a"}]},
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "a"}]},
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "b"}]},
        %{role: "assistant", content: [%{type: "tool_use", id: "c"}]},
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "c"}]}
      ]

      assert [
               %Message{role: "user", content: "q"},
               %Message{role: "assistant"},
               %Message{
                 role: "tool",
                 content: [%{tool_use_id: "a"}, %{tool_use_id: "b"}]
               },
               %Message{role: "assistant"},
               %Message{role: "tool", content: [%{tool_use_id: "c"}]}
             ] = AgentMemory.request_messages(history)
    end

    test "a tool message whose content is not a list stays its own message" do
      history = [
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "a"}]},
        %{role: "tool", content: "plain"},
        %{role: "tool", content: [%{type: "tool_result", tool_use_id: "b"}]}
      ]

      assert [
               %Message{content: [%{tool_use_id: "a"}]},
               %Message{content: "plain"},
               %Message{content: [%{tool_use_id: "b"}]}
             ] = AgentMemory.request_messages(history)
    end

    test "messages of other roles pass through unchanged" do
      history = [%{role: "user", content: "a"}, %{role: "user", content: "b"}]

      assert [%Message{role: "user", content: "a"}, %Message{role: "user", content: "b"}] =
               AgentMemory.request_messages(history)
    end
  end

  describe "a batch of two tool results" do
    test "run/3 sends one user message; memory keeps one entry per result" do
      client =
        WireScript.client([{:json, [@weather, @clock], "tool_use"}, {:json, [@done], "end_turn"}])

      assert {:ok, config, %{chat_message: "Done."}} = BaseAgent.run(agent(client), "go")

      assert_one_result_message()

      assert 2 ==
               config.memory |> AgentMemory.messages() |> Enum.count(&(&1.role == "tool"))
    end

    test "stream/3 sends one user message" do
      client =
        WireScript.client([
          {:sse, streamed("msg_0", [@weather, @clock], "tool_use")},
          {:sse, streamed_text("msg_1", "Done.")}
        ])

      assert {:ok, _config, %{chat_message: "Done."}} =
               BaseAgent.stream(agent(client), "go", fn _ -> :ok end)

      assert_one_result_message()
    end

    test "Turn.Server sends one user message; the store keeps one entry per result" do
      client =
        WireScript.client([{:json, [@weather, @clock], "tool_use"}, {:json, [@done], "end_turn"}])

      store = InMemory.new()
      srv = server(agent(client), "s-coalesce", store)

      assert {:ok, %{chat_message: "Done."}} = Server.run(srv, "go")
      assert_one_result_message()

      assert {:ok, entries} = InMemory.history(store, "s-coalesce")
      assert 2 == Enum.count(entries, &(&1.role == "tool"))
    end
  end

  describe "MCP connector blocks (AX-3)" do
    @mcp_use %{
      "type" => "mcp_tool_use",
      "id" => "mcptoolu_1",
      "name" => "search",
      "server_name" => "docs",
      "input" => %{"q" => "x"}
    }
    @mcp_result %{
      "type" => "mcp_tool_result",
      "tool_use_id" => "mcptoolu_1",
      "server_name" => "docs",
      "is_error" => false,
      "content" => [%{"type" => "text", "text" => "found"}]
    }

    # A local tool with the name the old adapter gave the MCP call.
    defp mcp_agent(client),
      do: agent(client, [%FakeTool{name: "docs__search", notify: self()}])

    test "extract_tool_uses/1 returns only client tool_use blocks" do
      response = %{content: [@mcp_use, @mcp_result, @weather]}

      assert [%ToolCall{id: "t1", name: "weather"}] = ClaudioAdapter.extract_tool_uses(response)
    end

    test "run/3 answers without dispatching the MCP call" do
      client =
        WireScript.client([{:json, [@mcp_use, @mcp_result, @done], "end_turn"}])

      assert {:ok, _config, %{chat_message: "Done."}} = BaseAgent.run(mcp_agent(client), "go")
      refute_received {:tool_ran, _}
      refute_received {:wire_body, 1, _}
    end

    test "Turn.Server answers without dispatching the MCP call" do
      client =
        WireScript.client([{:json, [@mcp_use, @mcp_result, @done], "end_turn"}])

      srv = server(mcp_agent(client), "s-mcp", InMemory.new())

      assert {:ok, %{chat_message: "Done."}} = Server.run(srv, "go")
      refute_received {:tool_ran, _}
      refute_received {:wire_body, 1, _}
    end

    test "stream/3 answers without dispatching the MCP call" do
      events =
        WireScript.message(
          "msg_0",
          WireScript.block(0, %{@mcp_use | "input" => %{}}, [
            %{"type" => "input_json_delta", "partial_json" => ~s({"q": "x"})}
          ]) ++
            WireScript.block(1, @mcp_result, []) ++
            WireScript.block(2, %{"type" => "text", "text" => ""}, [
              %{"type" => "text_delta", "text" => "Done."}
            ]),
          "end_turn"
        )

      client = WireScript.client([{:sse, events}])

      assert {:ok, _config, %{chat_message: "Done."}} =
               BaseAgent.stream(mcp_agent(client), "go", fn _ -> :ok end)

      refute_received {:tool_ran, _}
      refute_received {:wire_body, 1, _}
    end
  end
end
