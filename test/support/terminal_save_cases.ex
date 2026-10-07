defmodule Normandy.Test.TerminalSaveCases do
  @moduledoc """
  Task 7.0b (H10, Review Focus #1) on one session-store backend: a turn whose terminal
  save the store refuses is saved before the next turn, and an eager restart never asks
  the model again for a turn whose answer is stored.

  `use` it in a test module that also `use ExUnit.Case`, after any setup the backend
  needs (the store's `new/0` must return its handle, as for the store contract):

      use Normandy.Test.TerminalSaveCases, store: Normandy.Behaviours.SessionStore.ETS

  `config/1` and `start/5` are public for tests that need more than these two cases.
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Components.ToolCall
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.StubClient
  alias Normandy.Test.TerminalSaveStore

  @doc """
  An agent with one tool whose model answers in rounds of two calls: a call to the
  tool `"big"`, then the text `"done"`. Each call sends `{:converse, request, opts}`
  to `owner`.
  """
  @spec config(pid()) :: Normandy.Agents.BaseAgentConfig.t()
  def config(owner) do
    calls = :atomics.new(1, [])

    reply = fn _response_model ->
      n = :atomics.add_get(calls, 1, 1)

      if rem(n, 2) == 1,
        do: %ToolCallResponse{tool_calls: [%ToolCall{id: "call_#{n}", name: "big", input: %{}}]},
        else: %ToolCallResponse{content: "done", tool_calls: []}
    end

    %{client: %StubClient{notify: owner, reply: reply}, model: "m"}
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%ReturnTool{output: "ok"})
  end

  @doc """
  Starts an eager server for `sid` under `sup`, on `store` (a `TerminalSaveStore`), with
  `config(self())`; `opts` are added to the start options (`:idle_timeout_ms`).
  """
  @spec start(pid(), String.t(), TerminalSaveStore.t(), term(), keyword()) :: pid()
  def start(sup, sid, store, registry, opts \\ []) do
    {:ok, pid} =
      Turn.Supervisor.start_server(
        sup,
        [
          session_id: sid,
          config: config(self()),
          store: {TerminalSaveStore, store},
          registry: {Native, registry},
          resume_policy: :eager
        ] ++ opts
      )

    pid
  end

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)

    quote bind_quoted: [store: store] do
      alias Normandy.Agents.Turn
      alias Normandy.Behaviours.SessionRegistry.Native
      alias Normandy.Test.TerminalSaveCases
      alias Normandy.Test.TerminalSaveStore

      @terminal_save_backend store

      describe "a refused terminal save (#{inspect(store)})" do
        # The refusals log the expected warning; keep it out of the backend's test output.
        @describetag :capture_log

        setup do
          inner = {@terminal_save_backend, @terminal_save_backend.new()}

          {:ok,
           inner: inner,
           store: TerminalSaveStore.new(inner),
           sup: start_supervised!({Turn.Supervisor, max_restarts: 0}),
           registry: Native.new(),
           sid: "terminal-save-#{System.unique_integer([:positive])}"}
        end

        test "lands before the next turn starts; the session leaves the in-flight index", ctx do
          %{inner: {mod, h}, store: store, sid: sid} = ctx
          srv = TerminalSaveCases.start(ctx.sup, sid, store, ctx.registry)

          TerminalSaveStore.fail_terminal(store, true)
          assert {:ok, %{chat_message: "done"}} = Turn.Server.run(srv, %{chat_message: "one"})
          assert {:ok, [^sid]} = mod.list_resumable(h)
          assert {:ok, %Turn.State{status: :steering}} = mod.load_turn_state(h, sid)

          TerminalSaveStore.fail_terminal(store, false)
          assert {:ok, %{chat_message: "done"}} = Turn.Server.run(srv, %{chat_message: "two"})

          # The refused save is retried, and lands, before the second turn's first write.
          assert TerminalSaveStore.ops(store) == [
                   {:append, "user"},
                   {:append, "assistant"},
                   {:append, "tool"},
                   {:save, :steering, true, :ok},
                   {:append, "assistant"},
                   {:save, :stopped, false, :refused},
                   {:save, :stopped, false, :ok},
                   {:append, "user"},
                   {:append, "assistant"},
                   {:append, "tool"},
                   {:save, :steering, true, :ok},
                   {:append, "assistant"},
                   {:save, :stopped, false, :ok}
                 ]

          assert {:ok, []} = mod.list_resumable(h)
          assert {:ok, %Turn.State{status: :stopped}} = mod.load_turn_state(h, sid)
        end

        test "an eager restart makes no model call and stores no second answer", ctx do
          %{inner: {mod, h}, store: store, sid: sid} = ctx
          srv = TerminalSaveCases.start(ctx.sup, sid, store, ctx.registry)

          TerminalSaveStore.fail_terminal(store, true)
          assert {:ok, %{chat_message: "done"}} = Turn.Server.run(srv, %{chat_message: "one"})
          assert_received {:converse, _, _}
          assert_received {:converse, _, _}

          # The process dies before any retry lands (the window no retry can close).
          :ok = Turn.Supervisor.stop_server(ctx.sup, srv)
          TerminalSaveStore.fail_terminal(store, false)

          restarted = TerminalSaveCases.start(ctx.sup, sid, store, ctx.registry)
          # The load and the :resume event run before the server takes this message.
          assert {:idle, _data} = :sys.get_state(restarted)

          refute_received {:converse, _, _}
          {:ok, entries} = mod.history(h, sid)
          assert Enum.map(entries, & &1.role) == ["user", "assistant", "tool", "assistant"]
          assert {:ok, %Turn.State{status: :stopped}} = mod.load_turn_state(h, sid)
          assert {:ok, []} = mod.list_resumable(h)
        end
      end
    end
  end
end
