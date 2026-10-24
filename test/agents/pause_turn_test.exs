defmodule Normandy.Agents.PauseTurnTest do
  @moduledoc """
  Task 5.3c: a `pause_turn` response is sent back as it is, with no user message after
  it, and the model continues the turn; on the pure core, `Turn.Driver` from plain functions, `run/3`,
  `stream/3` and `Turn.Server`. An agent with MCP servers and no tools of its own runs
  the tool-loop response model, so its connector turns reach the loop.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Claudio.Messages.Response, as: ClaudioResponse
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.LLM.Request
  alias Normandy.MCP.ServerConfig
  alias Normandy.Test.FakeTool
  alias Normandy.Test.StubClient
  alias Normandy.Test.TurnShell
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  @search %{
    "type" => "server_tool_use",
    "id" => "srvtoolu_1",
    "name" => "web_search",
    "input" => %{"query" => "paris weather"}
  }
  @searching %{"type" => "text", "text" => "Searching."}
  @paused [@searching, @search]
  @result %{
    "type" => "web_search_tool_result",
    "tool_use_id" => "srvtoolu_1",
    "content" => [
      %{
        "type" => "web_search_result",
        "url" => "https://e.com",
        "title" => "P",
        "encrypted_content" => "e"
      }
    ]
  }
  @sunny %{"type" => "text", "text" => "Sunny."}

  defp paused_replay,
    do:
      %{"content" => @paused}
      |> ClaudioResponse.from_map()
      |> ClaudioResponse.to_assistant_content()

  defp paused_sse,
    do:
      WireScript.message(
        "msg_0",
        WireScript.block(0, %{"type" => "text", "text" => ""}, [
          %{"type" => "text_delta", "text" => "Searching."}
        ]) ++
          WireScript.block(1, %{@search | "input" => %{}}, [
            %{"type" => "input_json_delta", "partial_json" => ~s({"query": "paris weather"})}
          ]),
        "pause_turn"
      )

  defp continued_sse,
    do:
      WireScript.message(
        "msg_1",
        WireScript.block(0, @result, []) ++
          WireScript.block(1, %{"type" => "text", "text" => ""}, [
            %{"type" => "text_delta", "text" => "Sunny."}
          ]),
        "end_turn"
      )

  # The continuation: the user turn, then the paused assistant turn as it came, last.
  defp assert_continued do
    assert_received {:wire_body, 1, body}

    assert [%{"role" => "user"}, %{"role" => "assistant", "content" => content}] =
             body["messages"]

    assert content == paused_replay()
    refute_received {:wire_body, 2, _}
  end

  defp tool_agent(client) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      toolset: Toolset.new([%FakeTool{notify: self()}])
    })
  end

  describe "the core" do
    defp running(max) do
      {s, _} =
        Turn.step(Turn.new(max_iterations: max, response_model: :rm, output_schema: :os), :start)

      {s, _} = Turn.step(s, {:compaction_done, %{compacted: false}})
      s
    end

    for reason <- [:pause_turn, "pause_turn"] do
      test "a #{inspect(reason)} response is appended and the turn goes on" do
        resp = %{content: "Searching.", tool_calls: [], stop_reason: unquote(reason)}
        {s, effects} = Turn.step(running(3), {:llm_response, resp})

        assert s.status == :steering
        assert s.iterations_left == 2

        assert [
                 {:append_message, "assistant", ^resp},
                 {:persist, ^s},
                 {:emit_event, :steering, %{iterations_left: 2}},
                 {:maybe_compact, %{iterations_left: 2, mid_round: true}}
               ] = effects

        assert {_s, [_iteration, {:call_llm, %{response_model: :rm, final: false}}]} =
                 Turn.step(s, {:compaction_done, %{compacted: false}})
      end
    end

    test "a response without :stop_reason finishes as before" do
      {s, effects} =
        Turn.step(
          running(3),
          {:llm_response, %ToolCallResponse{content: "hi"} |> Map.delete(:stop_reason)}
        )

      assert s.status == :finalizing
      assert [{:convert_output, _, :os}] = effects
    end

    test "a model that keeps pausing reaches the forced final call" do
      paused = %{tool_calls: [], stop_reason: :pause_turn}
      {s, _} = Turn.step(running(1), {:llm_response, paused})

      assert {_s, [_iteration, {:call_llm, %{response_model: :rm, final: true}}]} =
               Turn.step(s, {:compaction_done, %{compacted: false}})
    end

    test "Turn.Driver from plain functions continues a paused turn" do
      test_pid = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      deps = %{
        call_llm: fn _request ->
          case Agent.get_and_update(calls, &{&1, &1 + 1}) do
            0 -> {:ok, %ToolCallResponse{content: "Searching.", stop_reason: :pause_turn}}
            1 -> {:ok, %ToolCallResponse{content: "Sunny.", stop_reason: :end_turn}}
          end
        end,
        dispatch: fn _calls -> flunk("a paused turn dispatches nothing") end,
        append: fn role, content -> send(test_pid, {:appended, role, content}) end
      }

      state = Turn.new(max_iterations: 3, response_model: :rm, output_schema: :os)
      assert {:ok, final} = TurnShell.run(state, deps)
      assert %ToolCallResponse{content: "Sunny."} = final.final_response
      assert_received {:appended, "assistant", %ToolCallResponse{stop_reason: :pause_turn}}
    end
  end

  describe "a paused server-tool turn" do
    test "run/3 sends it back unchanged and returns the continued answer" do
      client =
        WireScript.client([
          {:json, @paused, "pause_turn"},
          {:json, [@result, @sunny], "end_turn"}
        ])

      assert {:ok, config, %{chat_message: "Sunny."}} =
               BaseAgent.run(tool_agent(client), "weather?")

      assert_continued()
      refute_received {:tool_ran, _}

      assert [
               %ToolCallResponse{stop_reason: :pause_turn},
               %ToolCallResponse{tool_calls: [], content_blocks: [@result, @sunny]}
             ] =
               for(
                 %{role: "assistant", content: %ToolCallResponse{} = r} <-
                   AgentMemory.messages(config.memory),
                 do: r
               )
    end

    test "stream/3 sends it back unchanged and returns the continued answer" do
      client = WireScript.client([{:sse, paused_sse()}, {:sse, continued_sse()}])

      assert {:ok, _config, %{chat_message: "Sunny."}} =
               BaseAgent.stream(tool_agent(client), "weather?", fn _ -> :ok end)

      assert_continued()
    end

    test "Turn.Server sends it back unchanged and stores the paused turn" do
      client =
        WireScript.client([
          {:json, @paused, "pause_turn"},
          {:json, [@result, @sunny], "end_turn"}
        ])

      store = InMemory.new()

      {:ok, srv} =
        Server.start_link(
          session_id: "s-pause",
          config: tool_agent(client),
          store: {InMemory, store},
          registry: {Native, Native.new()}
        )

      assert {:ok, %{chat_message: "Sunny."}} = Server.run(srv, "weather?")
      assert_continued()

      assert {:ok, entries} = InMemory.history(store, "s-pause")

      assert [
               %ToolCallResponse{stop_reason: :pause_turn},
               %ToolCallResponse{tool_calls: [], content_blocks: [@result, @sunny]},
               %{chat_message: "Sunny."}
             ] = for(%{role: "assistant", content: c} <- entries, do: c)
    end
  end

  describe "an agent with MCP servers and no tools of its own" do
    defp mcp_agent(client) do
      BaseAgent.init(%{
        client: client,
        model: "claude-opus-5-5",
        mcp_servers: [ServerConfig.new("docs", "https://mcp.example.com/sse")]
      })
    end

    test "runs the tool-loop response model" do
      assert %ToolCallResponse{} = AgentHandlers.turn_response_model(mcp_agent(%StubClient{}))

      assert %Normandy.Agents.BaseAgentOutputSchema{} =
               AgentHandlers.turn_response_model(
                 BaseAgent.init(%{client: %StubClient{}, model: "m"})
               )
    end

    test "run/3 asks for a ToolCallResponse; a chat agent's prompt shows no output schema" do
      client = %StubClient{notify: self(), reply: fn rm -> %{rm | content: "Hi."} end}

      assert {:ok, _config, %{chat_message: "Hi."}} = BaseAgent.run(mcp_agent(client), "hi")

      assert_receive {:converse, %Request{response_model: %ToolCallResponse{}} = request, _}
      refute request.system =~ "# OUTPUT SCHEMA"
      assert [%ServerConfig{}] = request.mcp_servers
    end

    test "run/3 continues a paused connector turn" do
      client =
        WireScript.client([
          {:json, @paused, "pause_turn"},
          {:json, [@result, @sunny], "end_turn"}
        ])

      assert {:ok, _config, %{chat_message: "Sunny."}} =
               BaseAgent.run(mcp_agent(client), "weather?")

      assert_continued()
    end

    # The next turn's request: the paused turn whole, then the continuation's tool result
    # (its text goes once, as the answer), then the answer and the new input. Each
    # server-tool use is answered by a later block.
    defp assert_result_kept(body) do
      assert [
               %{"role" => "user"},
               %{"role" => "assistant", "content" => [@searching, @search]},
               %{"role" => "assistant", "content" => [@result]},
               %{"role" => "assistant", "content" => answer},
               %{"role" => "user"}
             ] = body["messages"]

      assert answer in ["Sunny.", [%{"type" => "text", "text" => "Sunny."}]]
    end

    test "a second run after a continued paused turn sends the tool result it got" do
      client =
        WireScript.client([
          {:json, @paused, "pause_turn"},
          {:json, [@result, @sunny], "end_turn"},
          {:json, [@sunny], "end_turn"}
        ])

      {:ok, config, _} = BaseAgent.run(mcp_agent(client), "weather?")
      assert {:ok, _config, %{chat_message: "Sunny."}} = BaseAgent.run(config, "and tomorrow?")

      assert_received {:wire_body, 2, body}
      assert_result_kept(body)
    end

    test "a second stream after a continued paused turn sends the tool result it got" do
      client =
        WireScript.client([
          {:sse, paused_sse()},
          {:sse, continued_sse()},
          {:sse,
           WireScript.message(
             "msg_2",
             WireScript.block(0, %{"type" => "text", "text" => ""}, [
               %{"type" => "text_delta", "text" => "Sunny."}
             ]),
             "end_turn"
           )}
        ])

      {:ok, config, _} = BaseAgent.stream(mcp_agent(client), "weather?", fn _ -> :ok end)

      assert {:ok, _config, %{chat_message: "Sunny."}} =
               BaseAgent.stream(config, "and tomorrow?", fn _ -> :ok end)

      assert_received {:wire_body, 2, body}
      assert_result_kept(body)
    end

    test "Turn.Server stores the continuation's tool result for the next turn" do
      client =
        WireScript.client([
          {:json, @paused, "pause_turn"},
          {:json, [@result, @sunny], "end_turn"},
          {:json, [@sunny], "end_turn"}
        ])

      store = {InMemory, InMemory.new()}

      # A second server on the same store: the next turn reads the stored history.
      start = fn ->
        Server.start_link(
          session_id: "s-pause-keep",
          config: mcp_agent(client),
          store: store,
          registry: {Native, Native.new()}
        )
      end

      {:ok, first} = start.()
      assert {:ok, %{chat_message: "Sunny."}} = Server.run(first, "weather?")
      :ok = GenServer.stop(first)

      {:ok, second} = start.()
      assert {:ok, %{chat_message: "Sunny."}} = Server.run(second, "and tomorrow?")

      assert_received {:wire_body, 2, body}
      assert_result_kept(body)
    end

    test "Turn.Server continues a paused connector turn" do
      client =
        WireScript.client([
          {:json, @paused, "pause_turn"},
          {:json, [@result, @sunny], "end_turn"}
        ])

      {:ok, srv} =
        Server.start_link(
          session_id: "s-pause-mcp",
          config: mcp_agent(client),
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:ok, %{chat_message: "Sunny."}} = Server.run(srv, "weather?")
      assert_continued()
    end
  end
end
