defmodule AutoresumeDemo.StoreTest do
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.SessionStore.Postgres, as: PG
  alias Normandy.Agents.Turn

  @store AutoresumeDemo.Repo

  test "save then load a non-terminal turn state round-trips" do
    sid = "store-test-#{System.unique_integer([:positive])}"
    :ok = PG.save_turn_state(@store, sid, %Turn.State{status: :steering, iterations_left: 3})

    assert {:ok, %Turn.State{status: :steering, iterations_left: 3}} =
             PG.load_turn_state(@store, sid)
  end

  test "an eager session shows up in list_resumable" do
    sid = "resumable-#{System.unique_integer([:positive])}"
    tmpl = %{template_id: "research", resume_policy: :eager}
    :ok = PG.save_config_template(@store, sid, tmpl)
    :ok = PG.save_turn_state(@store, sid, %Turn.State{status: :steering, iterations_left: 1})

    assert {:ok, sids} = PG.list_resumable(@store)
    assert sid in sids
  end
end
