defmodule AutoresumeDemo.StoreTest do
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.SessionStore.Postgres, as: PG
  alias Normandy.Agents.Turn

  @store AutoresumeDemo.Repo

  # Delete only the session rows the test created (these tests create no entries,
  # so the entries table needs no cleanup). Scoped to exact session_ids via the
  # demo Repo so we don't depend on a store delete API and never touch other rows.
  defp cleanup_sessions(session_ids) do
    on_exit(fn ->
      for sid <- session_ids do
        @store.query!("DELETE FROM normandy_sessions WHERE session_id = $1", [sid])
      end
    end)
  end

  test "save then load a non-terminal turn state round-trips" do
    sid = "store-test-#{System.unique_integer([:positive])}"
    cleanup_sessions([sid])
    :ok = PG.save_turn_state(@store, sid, %Turn.State{status: :steering, iterations_left: 3})

    assert {:ok, %Turn.State{status: :steering, iterations_left: 3}} =
             PG.load_turn_state(@store, sid)
  end

  test "an eager session shows up in list_resumable but a lazy one does not" do
    sid = "resumable-#{System.unique_integer([:positive])}"
    lazy_sid = "lazy-#{System.unique_integer([:positive])}"
    cleanup_sessions([sid, lazy_sid])

    :ok = PG.save_config_template(@store, sid, %{template_id: "research", resume_policy: :eager})
    :ok = PG.save_turn_state(@store, sid, %Turn.State{status: :steering, iterations_left: 1})

    :ok =
      PG.save_config_template(@store, lazy_sid, %{template_id: "research", resume_policy: :lazy})

    :ok = PG.save_turn_state(@store, lazy_sid, %Turn.State{status: :steering, iterations_left: 1})

    assert {:ok, sids} = PG.list_resumable(@store)
    assert sid in sids
    refute lazy_sid in sids
  end
end
