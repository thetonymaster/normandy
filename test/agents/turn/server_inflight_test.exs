defmodule Normandy.Agents.Turn.ServerInflightTest do
  @moduledoc """
  Task 6.3c (PERF-8): Turn.Server saves whether a turn is in flight with every turn
  state, so the store's `list_resumable/1` names an `:eager` session only while its turn
  runs or waits for approval.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log
  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.PolicyEngine.Ruleset
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.ToolCall
  alias Normandy.Test.FakeTool
  alias Normandy.Test.TurnConfig
  alias Normandy.Test.TurnConfig.Resp
  alias Normandy.Tools.Toolset

  # The first call asks for the billing tool, which needs approval; the next answers.
  defp handlers do
    calls = :counters.new(1, [])

    call_llm = fn _config, _state, _request ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1,
        do: %Resp{content: "", tool_calls: [%ToolCall{id: "pk1", name: "billing", input: %{}}]},
        else: %Resp{content: "done", tool_calls: nil}
    end

    %{AgentHandlers.non_streaming_handlers() | call_llm: call_llm}
  end

  defp config do
    %{
      TurnConfig.build()
      | toolset: Toolset.new([%FakeTool{name: "billing"}]),
        behaviours: %Normandy.Behaviours.Config{
          policy:
            {Ruleset,
             rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
             default_action: :allow}
        }
    }
  end

  defp start(store, sid, resume_policy) do
    test_pid = self()

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config(),
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: handlers(),
        resume_policy: resume_policy,
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      )

    caller = Task.async(fn -> Turn.Server.run(srv, "bill me") end)
    assert_receive {:event, :awaiting_approval, _meta}, 2_000
    {srv, caller}
  end

  test "an :eager session is listed while parked and dropped when its turn ends" do
    store = InMemory.new()
    {srv, caller} = start(store, "s-eager", :eager)

    assert wait_until(fn -> InMemory.list_resumable(store) == {:ok, ["s-eager"]} end)

    :ok = Turn.Server.approve(srv, %{"pk1" => :approve})
    assert {:ok, %Resp{content: "done"}} = Task.await(caller, 2_000)

    assert {:ok, %Turn.State{status: :stopped}} = InMemory.load_turn_state(store, "s-eager")
    assert {:ok, []} = InMemory.list_resumable(store)
  end

  test "a :lazy session is never listed" do
    store = InMemory.new()
    {_srv, _caller} = start(store, "s-lazy", :lazy)

    assert wait_until(fn ->
             match?(
               {:ok, %Turn.State{status: :awaiting_approval}},
               InMemory.load_turn_state(store, "s-lazy")
             )
           end)

    assert {:ok, []} = InMemory.list_resumable(store)
  end
end
