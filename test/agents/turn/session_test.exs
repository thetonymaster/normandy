defmodule Normandy.Agents.Turn.SessionTest do
  use ExUnit.Case, async: false
  alias Normandy.Agents.Turn

  test "supervisor starts a Turn.Server child as transient" do
    {:ok, sup} = Turn.Supervisor.start_link([])

    {:ok, pid} =
      Turn.Supervisor.start_server(sup,
        session_id: "x",
        config: nil,
        store:
          {Normandy.Behaviours.SessionStore.InMemory,
           Normandy.Behaviours.SessionStore.InMemory.new()},
        registry:
          {Normandy.Behaviours.SessionRegistry.Native,
           Normandy.Behaviours.SessionRegistry.Native.new()}
      )

    assert is_pid(pid)
    assert [{:undefined, ^pid, :worker, _}] = DynamicSupervisor.which_children(sup)
  end
end
