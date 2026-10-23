defmodule Normandy.Agents.Turn.SessionDeleteTest do
  @moduledoc """
  Task 6.3e (PERF-8, decision 24 R8): `Turn.Session.delete/1` stops the live server
  through the supervisor, then deletes the session from the store.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log
  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Session
  alias Normandy.Behaviours.PolicyEngine.Ruleset
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.ToolCall
  alias Normandy.Test.FakeTool
  alias Normandy.Test.TurnConfig
  alias Normandy.Test.TurnConfig.Resp
  alias Normandy.Tools.Toolset
  alias Normandy.TurnError

  defmodule DownRegistry do
    @moduledoc false
    def whereis(_handle, _sid), do: {:error, :registry_down}
  end

  defmodule RefusingStore do
    @moduledoc false
    def delete_session(_handle, _sid), do: {:error, :disk_full}
  end

  # A store whose call exits, as a GenServer.call to a stuck store process does.
  defmodule ExitingStore do
    @moduledoc false
    def delete_session(_handle, sid),
      do: exit({:timeout, {GenServer, :call, [:store, {:delete_session, sid}, 5_000]}})
  end

  defmodule RaisingStore do
    @moduledoc false
    def delete_session(_handle, _sid), do: raise("store bug")
  end

  # A supervisor whose stop_server/2 never finds the child.
  defmodule ForeignSupervisor do
    @moduledoc false
    @behaviour Normandy.Agents.Turn.ServerSupervisor

    def start_server(_sup, _opts), do: {:error, :unused}
    def stop_server(_sup, _pid), do: {:error, :not_found}
  end

  defmodule NoStopSupervisor do
    @moduledoc false
    def start_server(_sup, _opts), do: {:error, :unused}
  end

  defp session(store, reg, sup, extra \\ []) do
    Session.new(
      Keyword.merge(
        [
          session_id: "s-del",
          config: TurnConfig.build(),
          store: {InMemory, store},
          registry: {Native, reg},
          supervisor: sup,
          handlers: %{
            AgentHandlers.non_streaming_handlers()
            | call_llm: fn _c, _s, _r -> %Resp{content: "ok"} end
          }
        ],
        extra
      )
    )
  end

  defp setup_infra do
    {:ok, sup} = Turn.Supervisor.start_link([])
    {InMemory.new(), Native.new(), sup}
  end

  defp seed(store), do: InMemory.append_entry(store, "s-del", %Entry{role: "user", content: "a"})

  test "stops the live server and deletes the stored session" do
    {store, reg, sup} = setup_infra()
    session = session(store, reg, sup)
    assert {:ok, %Resp{content: "ok"}} = Session.run(session, "hello")
    {:ok, pid} = Native.whereis(reg, "s-del")
    ref = Process.monitor(pid)

    assert :ok = Session.delete(session)

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
    assert DynamicSupervisor.which_children(sup) == []
    assert {:ok, []} = InMemory.history(store, "s-del")
    assert :error = InMemory.load_turn_state(store, "s-del")
    assert wait_until(fn -> Native.whereis(reg, "s-del") == :none end)
  end

  test "with no live server it deletes the stored session; again is :ok" do
    {store, reg, sup} = setup_infra()
    {:ok, _} = seed(store)

    assert :ok = Session.delete(session(store, reg, sup))
    assert {:ok, []} = InMemory.history(store, "s-del")
    assert :ok = Session.delete(session(store, reg, sup))
  end

  # The plan's acceptance: the eager set shrinks after a session is deleted.
  test "an :eager session parked mid-turn leaves the in-flight index and its caller exits" do
    {store, reg, sup} = setup_infra()
    test_pid = self()

    call_llm = fn _c, _s, _r ->
      %Resp{content: "", tool_calls: [%ToolCall{id: "pk1", name: "billing", input: %{}}]}
    end

    config = %{
      TurnConfig.build()
      | toolset: Toolset.new([%FakeTool{name: "billing"}]),
        behaviours: %Normandy.Behaviours.Config{
          policy:
            {Ruleset,
             rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
             default_action: :allow}
        }
    }

    session =
      session(store, reg, sup,
        config: config,
        resume_policy: :eager,
        handlers: %{AgentHandlers.non_streaming_handlers() | call_llm: call_llm},
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      )

    # Start the server, then call it directly: the exit is the caller's to observe
    # (Session.run/2 may retry a stopped server, Task 6.2d).
    {:ok, pid} =
      Turn.Supervisor.start_server(sup,
        session_id: "s-del",
        config: config,
        store: {InMemory, store},
        registry: {Native, reg},
        resume_policy: :eager,
        handlers: session.handlers,
        subscriber: session.subscriber
      )

    spawn(fn ->
      result =
        try do
          Turn.Server.run(pid, "bill me")
        catch
          :exit, reason -> {:exited, reason}
        end

      send(test_pid, {:caller, result})
    end)

    assert_receive {:event, :awaiting_approval, _}, 2_000
    assert wait_until(fn -> InMemory.list_resumable(store) == {:ok, ["s-del"]} end)

    assert :ok = Session.delete(session)

    assert {:ok, []} = InMemory.list_resumable(store)
    assert_receive {:caller, {:exited, {:shutdown, _call}}}, 1_000
  end

  test "through the Horde supervisor too" do
    alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
    alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

    reg = HReg.new()
    sup = :"del_#{System.unique_integer([:positive])}"
    {:ok, _} = HSup.start_link(name: sup)
    store = InMemory.new()
    session = session(store, nil, sup, supervisor_mod: HSup, registry: {HReg, reg})

    assert {:ok, %Resp{content: "ok"}} = Session.run(session, "hello")
    assert wait_until(fn -> match?({:ok, _}, HReg.whereis(reg, "s-del")) end)
    {:ok, pid} = HReg.whereis(reg, "s-del")
    ref = Process.monitor(pid)

    assert :ok = Session.delete(session)

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
    assert {:ok, []} = InMemory.history(store, "s-del")
    assert {:error, :not_found} = HSup.stop_server(sup, pid)
  end

  test "a registry that cannot answer deletes nothing" do
    {store, _reg, sup} = setup_infra()
    {:ok, _} = seed(store)
    session = session(store, nil, sup, registry: {DownRegistry, nil})

    assert {:error, %TurnError{type: :session_unavailable, reason: :registry_down}} =
             Session.delete(session)

    assert {:ok, [_]} = InMemory.history(store, "s-del")
  end

  test "a live server the supervisor does not own deletes nothing" do
    {store, reg, _sup} = setup_infra()
    :ok = Native.register(reg, "s-del", self())
    {:ok, _} = seed(store)
    session = session(store, reg, :unused, supervisor_mod: ForeignSupervisor)

    assert {:error, %TurnError{type: :session_unavailable, reason: {:not_stopped, :not_found}}} =
             Session.delete(session)

    assert {:ok, [_]} = InMemory.history(store, "s-del")
  end

  test "a store that refuses the delete is a :persist_failed TurnError" do
    {_store, reg, sup} = setup_infra()
    session = session(nil, reg, sup, store: {RefusingStore, nil})

    assert {:error, %TurnError{type: :persist_failed, reason: :disk_full}} =
             Session.delete(session)
  end

  # Decision 25 (A6): a store exit is a failed delete, as in Turn.Server (Task 6.2a's
  # store_call/1); the call's arguments (the session id here) are not in the reason.
  test "a store that exits is a :persist_failed TurnError with {:store_exit, tag}" do
    {_store, reg, sup} = setup_infra()
    session = session(nil, reg, sup, store: {ExitingStore, nil})

    assert {:error,
            %TurnError{
              type: :persist_failed,
              reason: {:store_exit, {:timeout, {GenServer, :call, "a list"}}}
            }} = Session.delete(session)
  end

  test "a store that raises raises (a bug, not a failed delete)" do
    {_store, reg, sup} = setup_infra()
    session = session(nil, reg, sup, store: {RaisingStore, nil})

    assert_raise RuntimeError, "store bug", fn -> Session.delete(session) end
  end

  # new/1 refuses such a module (Turn.ServerSupervisor); a handle edited after it is
  # still caught here.
  test "a :supervisor_mod without stop_server/2 raises, naming it" do
    {store, reg, _sup} = setup_infra()
    session = %{session(store, reg, :unused) | supervisor_mod: NoStopSupervisor}

    assert_raise ArgumentError,
                 "Normandy.Agents.Turn.Session.delete/1: the :supervisor_mod " <>
                   "Normandy.Agents.Turn.SessionDeleteTest.NoStopSupervisor does not export " <>
                   "stop_server/2, so the session's server cannot be stopped",
                 fn -> Session.delete(session) end
  end

  test "a non-session argument raises" do
    assert_raise ArgumentError,
                 ~r/delete\/1: expected a %Normandy.Agents.Turn.Session\{\}.*got: a map/,
                 fn -> Session.delete(%{}) end
  end
end
