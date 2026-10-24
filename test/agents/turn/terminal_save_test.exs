defmodule Normandy.Agents.Turn.TerminalSaveTest do
  @moduledoc """
  Task 7.0b (H10, decision 27 A1/A2): a terminal turn-state save the store refuses is
  logged, kept and saved again (before the next turn, at passivation, on a timer); turns
  are refused meanwhile; a resumed turn whose answer is stored makes no model call.
  `Normandy.Test.TerminalSaveCases` runs on InMemory at the end of this file and in each
  other backend's store test.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  import Normandy.Test.Eventually

  alias Normandy.Agents.{BaseAgentInputSchema, BaseAgentOutputSchema, ToolCallResponse, Turn}
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.{Message, ToolCall}
  alias Normandy.Test.{Hooks, TerminalSaveCases, TerminalSaveStore}
  alias Normandy.Test.Hooks.TurnEndOnly
  alias Normandy.TurnError

  setup do
    mem = InMemory.new()

    {:ok,
     mem: mem,
     store: TerminalSaveStore.new({InMemory, mem}),
     sup: start_supervised!({Turn.Supervisor, max_restarts: 0}),
     registry: Native.new(),
     sid: "terminal-save-#{System.unique_integer([:positive])}"}
  end

  defp start(ctx, opts \\ []),
    do: TerminalSaveCases.start(ctx.sup, ctx.sid, ctx.store, ctx.registry, opts)

  defp refused_saves(store),
    do: Enum.count(TerminalSaveStore.ops(store), &match?({:save, _, _, :refused}, &1))

  describe "a refused terminal save" do
    test "is logged by its tag with the session id; the turn still replies {:ok, _}", ctx do
      srv = start(ctx)
      TerminalSaveStore.fail_terminal(ctx.store, true)

      log =
        ExUnit.CaptureLog.capture_log([metadata: [:session_id]], fn ->
          assert {:ok, %BaseAgentOutputSchema{chat_message: "done"}} =
                   Turn.Server.run(srv, %{chat_message: "one"})
        end)

      assert log =~
               "session_id=#{ctx.sid} [warning] Turn.Server session #{inspect(ctx.sid)}: " <>
                 "turn state not saved; retrying (:store_down)"

      assert {:ok, [_]} = InMemory.list_resumable(ctx.mem)
    end

    test "refuses the next turn with :persist_failed while the store still refuses it", ctx do
      srv = start(ctx)
      TerminalSaveStore.fail_terminal(ctx.store, true)
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "one"})
      assert_received {:converse, _, _}
      assert_received {:converse, _, _}
      {:ok, before} = InMemory.history(ctx.mem, ctx.sid)

      assert {:error, %TurnError{} = error} = Turn.Server.run(srv, %{chat_message: "two"})
      assert error.type == :persist_failed
      assert error.reason == {:terminal_unsaved, :store_down}

      assert Exception.message(error) ==
               "turn failed: persist failed: the session store rejected a write " <>
                 "({:terminal_unsaved, ...})"

      refute_received {:converse, _, _}
      assert InMemory.history(ctx.mem, ctx.sid) == {:ok, before}
      assert {:ok, %Turn.State{status: :steering}} = InMemory.load_turn_state(ctx.mem, ctx.sid)

      TerminalSaveStore.fail_terminal(ctx.store, false)

      assert {:ok, %BaseAgentOutputSchema{chat_message: "done"}} =
               Turn.Server.run(srv, %{chat_message: "two"})

      assert {:ok, []} = InMemory.list_resumable(ctx.mem)
    end

    test "fires on_turn_end with {:error, exception} for the refused turn request", ctx do
      config = TerminalSaveCases.config(self())
      hooks = [{TurnEndOnly, notify: Hooks.sink()}]
      config = %{config | behaviours: %Config{hooks: hooks}}

      {:ok, srv} =
        Turn.Supervisor.start_server(ctx.sup,
          session_id: ctx.sid,
          config: config,
          store: {TerminalSaveStore, ctx.store},
          registry: {Native, ctx.registry},
          resume_policy: :eager
        )

      TerminalSaveStore.fail_terminal(ctx.store, true)
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "one"})
      assert_receive {:turn_end_only, {:ok, _}}

      assert {:error, %TurnError{type: :persist_failed, reason: {:terminal_unsaved, _}}} =
               Turn.Server.run(srv, %{chat_message: "two"})

      # on_turn_end runs after the reply, in the server.
      assert_receive {:turn_end_only,
                      {:error, %TurnError{type: :persist_failed, reason: {:terminal_unsaved, _}}}}
    end

    test "is saved by the retry timer with no turn request", ctx do
      srv = start(ctx)
      TerminalSaveStore.fail_terminal(ctx.store, true)
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "one"})
      TerminalSaveStore.fail_terminal(ctx.store, false)

      # The first retry fires 1_000 ms after the refusal. TerminalSaveStore records a
      # save after the wrapped store wrote it, so wait for the record.
      assert wait_until(
               fn ->
                 List.last(TerminalSaveStore.ops(ctx.store)) == {:save, :stopped, false, :ok}
               end,
               300
             )

      assert {:ok, []} = InMemory.list_resumable(ctx.mem)
      assert {:ok, %Turn.State{status: :stopped}} = InMemory.load_turn_state(ctx.mem, ctx.sid)
      assert Process.alive?(srv)
    end

    test "defers passivation until it lands", ctx do
      srv = start(ctx, idle_timeout_ms: 20)
      ref = Process.monitor(srv)
      TerminalSaveStore.fail_terminal(ctx.store, true)
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "one"})

      # The turn's own save, then at least two passivations that found it unsaved.
      assert wait_until(fn -> refused_saves(ctx.store) >= 3 end)
      refute_received {:DOWN, ^ref, :process, ^srv, _}
      assert Native.whereis(ctx.registry, ctx.sid) == {:ok, srv}

      TerminalSaveStore.fail_terminal(ctx.store, false)
      assert_receive {:DOWN, ^ref, :process, ^srv, {:shutdown, :passivated}}, 2_000
      assert {:ok, []} = InMemory.list_resumable(ctx.mem)
    end
  end

  describe "an eager resume of a saved :steering turn" do
    test "whose history ends in a paused turn calls the model", ctx do
      paused = %ToolCallResponse{content: "searching", tool_calls: [], stop_reason: :pause_turn}

      for {role, content} <- [
            {"user", %BaseAgentInputSchema{chat_message: "one"}},
            {"assistant", paused}
          ] do
        entry = %Entry{id: UUID.uuid4(), turn_id: "t1", role: role, content: content}
        {:ok, _} = InMemory.append_entry(ctx.mem, ctx.sid, entry)
      end

      steering = %Turn.State{status: :steering, iterations_left: 5, max_iterations: 5}
      :ok = InMemory.save_turn_state(ctx.mem, ctx.sid, steering, true)

      _srv = start(ctx)

      # The load, the resume and the call's task run before the message: under a full
      # suite they can take longer than assert_receive's default 100 ms.
      assert_receive {:converse, _request, _opts}, 5_000

      # Let the resumed turn end here: its terminal save must not reach the store (whose
      # process is linked to this test) after the test has exited.
      assert wait_until(fn ->
               List.last(TerminalSaveStore.ops(ctx.store)) == {:save, :stopped, false, :ok}
             end)
    end
  end

  describe "Turn.answered?/1" do
    @answer %Message{role: "assistant", content: %BaseAgentOutputSchema{chat_message: "done"}}
    @user %Message{role: "user", content: %BaseAgentInputSchema{chat_message: "one"}}
    @call %ToolCall{id: "c1", name: "big", input: %{}}

    test "is true when the last message is an assistant answer" do
      assert Turn.answered?([@user, @answer])
      assert Turn.answered?([@user, %Message{role: "assistant", content: "done"}])
    end

    test "is false for a tool call, a paused turn, a tool result, a user message or nothing" do
      tool_use = %Message{role: "assistant", content: %ToolCallResponse{tool_calls: [@call]}}
      paused = %ToolCallResponse{tool_calls: [], stop_reason: :pause_turn}
      paused_wire = %{paused | stop_reason: "pause_turn"}

      refute Turn.answered?([])
      refute Turn.answered?([@user])
      refute Turn.answered?([@user, tool_use])
      refute Turn.answered?([@user, %Message{role: "assistant", content: paused}])
      refute Turn.answered?([@user, %Message{role: "assistant", content: paused_wire}])
      refute Turn.answered?([@user, tool_use, %Message{role: "tool", content: "ok"}])
      refute Turn.answered?([@user, @answer, @user])
    end
  end
end

defmodule Normandy.Agents.Turn.TerminalSaveInMemoryTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  use Normandy.Test.TerminalSaveCases, store: Normandy.Behaviours.SessionStore.InMemory
end
