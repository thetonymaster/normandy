defmodule Normandy.Agents.Turn.ServerPausedInputTest do
  @moduledoc """
  Task 7.6b (scenario 16): a session whose stored history ends in a paused turn (an MCP
  connector's `mcp_tool_use` with no `mcp_tool_result`, `stop_reason` `pause_turn`) can
  take new input. `Turn.Server` continues the paused turn first, as a resumed run, then
  runs the input; a continuation that fails fails that `run/2` and appends nothing, and
  the next `run/2` tries again.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema, BaseAgentOutputSchema}
  alias Normandy.Agents.{ToolCallResponse, Turn}
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.PolicyEngine.Ruleset
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.LLMError
  alias Normandy.MCP.ServerConfig
  alias Normandy.Test.FakeTool
  alias Normandy.Test.TelemetryCapture
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

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
  @overloaded %{
    "type" => "error",
    "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
  }

  @paused %ToolCallResponse{content_blocks: [@mcp_use], tool_calls: [], stop_reason: :pause_turn}

  setup do
    sid = "paused-input-#{System.unique_integer([:positive])}"
    store = InMemory.new()
    {:ok, _} = InMemory.append_entry(store, sid, entry("user", user("q1")))
    {:ok, _} = InMemory.append_entry(store, sid, entry("assistant", @paused))

    run_start = TelemetryCapture.attach([[:normandy, :agent, :run, :start]], session_id: sid)

    %{sid: sid, store: store, run_start: run_start}
  end

  defp entry(role, content), do: %Entry{turn_id: "t1", role: role, content: content}
  defp user(text), do: %BaseAgentInputSchema{chat_message: text}

  defp agent(client) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      mcp_servers: [ServerConfig.new("docs", "https://mcp.example.com/sse")]
    })
  end

  # The turn state a paused loop call saves (Turn.continue_paused/2: one iteration spent).
  defp steering_state do
    state =
      Turn.new(
        max_iterations: 20,
        response_model: %ToolCallResponse{},
        output_schema: %BaseAgentOutputSchema{}
      )

    %{state | status: :steering, iterations_left: 19}
  end

  defp failed_state do
    error = LLMError.new(type: :server, retryable?: true, status: 500)
    %{steering_state() | status: :failed, error: error}
  end

  defp start_server(ctx, replies, turn_state) do
    :ok = InMemory.save_turn_state(ctx.store, ctx.sid, turn_state, false)

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: ctx.sid,
        config: agent(WireScript.client(replies)),
        store: {InMemory, ctx.store},
        registry: {Native, Native.new()}
      )

    srv
  end

  defp stored(ctx) do
    {:ok, entries} = InMemory.history(ctx.store, ctx.sid)
    Enum.map(entries, &{&1.role, &1.content})
  end

  # Request n continues the paused turn: its last message is that turn as stored, with
  # no user message after it.
  defp assert_continuation(n) do
    assert_received {:wire_body, ^n, body}

    assert [%{"role" => "user"}, %{"role" => "assistant", "content" => [@mcp_use]}] =
             body["messages"]
  end

  # Request n runs "q2": the continuation's answer, then q2, last.
  defp assert_q2_request(n) do
    assert_received {:wire_body, ^n, body}
    messages = body["messages"]

    assert %{"role" => "user", "content" => q2} = List.last(messages)
    assert inspect(q2) =~ "q2"

    assert %{"role" => "assistant", "content" => answer} = Enum.at(messages, -2)
    assert inspect(answer) =~ "Found it."
  end

  defp spans do
    receive do
      {:span, event, meta} -> [{event, meta} | spans()]
    after
      0 -> []
    end
  end

  defp assert_answered_history(ctx) do
    assert [
             {"user", %BaseAgentInputSchema{chat_message: "q1"}},
             {"assistant", %ToolCallResponse{stop_reason: :pause_turn}},
             {"assistant", %BaseAgentOutputSchema{chat_message: "Found it."}},
             {"user", %BaseAgentInputSchema{chat_message: "q2"}},
             {"assistant", %BaseAgentOutputSchema{chat_message: "Answer two."}}
           ] = stored(ctx)
  end

  for {label, turn_state} <- [steering: :steering_state, failed: :failed_state] do
    test "a saved #{label} state: the paused turn is continued, then the input runs", ctx do
      srv =
        start_server(
          ctx,
          [
            {:json, [@mcp_result, @found], "end_turn"},
            {:json, [@answer_two], "end_turn"}
          ],
          unquote(turn_state)()
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Answer two."}} =
               Turn.Server.run(srv, "q2")

      assert_continuation(0)
      assert_q2_request(1)
      refute_received {:wire_body, 2, _}
      assert_answered_history(ctx)

      run_start = ctx.run_start
      assert_received {:telemetry, ^run_start, _, %{resumed: true}}
      assert_received {:telemetry, ^run_start, _, meta}
      refute Map.get(meta, :resumed)
    end
  end

  test "a continuation that fails fails run/2, appends nothing, and the next run/2 retries",
       ctx do
    srv =
      start_server(
        ctx,
        [
          {:status, 529, @overloaded},
          {:json, [@mcp_result, @found], "end_turn"},
          {:json, [@answer_two], "end_turn"}
        ],
        steering_state()
      )

    TelemetryCapture.attach_span(
      [[:normandy, :agent, :run, :start], [:normandy, :agent, :run, :exception]],
      session_id: ctx.sid
    )

    assert {:error, %LLMError{status: 529}} = Turn.Server.run(srv, "q2")
    assert_continuation(0)
    refute_received {:wire_body, 1, _}

    # The continuation is a resumed run that fails; the refused request is a run of its
    # own (no resumed flag) that fails with the same error.
    assert [
             {[:normandy, :agent, :run, :start], %{resumed: true}},
             {[:normandy, :agent, :run, :exception], %{resumed: true, reason: %LLMError{}}},
             {[:normandy, :agent, :run, :start], refused_start},
             {[:normandy, :agent, :run, :exception], %{reason: %LLMError{status: 529}} = refused}
           ] = spans()

    refute Map.has_key?(refused_start, :resumed)
    refute Map.has_key?(refused, :resumed)

    assert [
             {"user", %BaseAgentInputSchema{chat_message: "q1"}},
             {"assistant", %ToolCallResponse{stop_reason: :pause_turn}}
           ] = stored(ctx)

    assert {:ok, %BaseAgentOutputSchema{chat_message: "Answer two."}} =
             Turn.Server.run(srv, "q2")

    assert_continuation(1)
    assert_q2_request(2)
    assert_answered_history(ctx)
  end

  test "a continuation that parks for approval holds the input until the approval resolves",
       ctx do
    billing = %{"type" => "tool_use", "id" => "pk1", "name" => "billing", "input" => %{}}

    config =
      agent(
        WireScript.client([
          {:json, [@mcp_result, billing], "tool_use"},
          {:json, [@found], "end_turn"},
          {:json, [@answer_two], "end_turn"}
        ])
      )

    config = %{
      config
      | toolset: Toolset.new([%FakeTool{name: "billing"}]),
        behaviours: %Config{
          policy:
            {Ruleset,
             rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
             default_action: :allow}
        }
    }

    parent = self()
    :ok = InMemory.save_turn_state(ctx.store, ctx.sid, steering_state(), false)

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: ctx.sid,
        config: config,
        store: {InMemory, ctx.store},
        registry: {Native, Native.new()},
        subscriber: fn name, meta -> send(parent, {:event, name, meta}) end
      )

    task = Task.async(fn -> Turn.Server.run(srv, "q2") end)

    assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
    assert_received {:wire_body, 0, _}
    # Parked: run/2 is still waiting, and q2 has not reached the model.
    assert Task.yield(task, 100) == nil
    refute_received {:wire_body, 1, _}

    :ok = Turn.Server.approve(srv, %{"pk1" => :approve})

    assert {:ok, %BaseAgentOutputSchema{chat_message: "Answer two."}} = Task.await(task, 5_000)

    assert_received {:wire_body, 1, _}
    assert_received {:wire_body, 2, body}
    assert %{"role" => "user", "content" => q2} = List.last(body["messages"])
    assert inspect(q2) =~ "q2"
  end
end
