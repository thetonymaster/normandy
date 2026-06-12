defmodule Normandy.Behaviours.SessionStore.ETSTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore.ETS
  alias Normandy.Components.AgentMemory.Entry

  setup do
    {:ok, handle: ETS.new()}
  end

  test "append_entry returns an id; history is chronological", %{handle: h} do
    {:ok, _} = ETS.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "a"})
    {:ok, _} = ETS.append_entry(h, "s1", %Entry{turn_id: "t", role: "assistant", content: "b"})
    assert {:ok, entries} = ETS.history(h, "s1")
    assert Enum.map(entries, & &1.content) == ["a", "b"]
  end

  test "history on an unknown session is empty", %{handle: h} do
    assert {:ok, []} = ETS.history(h, "missing")
  end

  test "fork yields the ancestor chain and isolates appends", %{handle: h} do
    {:ok, _} = ETS.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "a"})
    {:ok, at} = ETS.append_entry(h, "s1", %Entry{turn_id: "t", role: "assistant", content: "b"})
    {:ok, _} = ETS.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "c"})

    {:ok, forked} = ETS.fork(h, "s1", at)
    {:ok, _} = ETS.append_entry(h, forked, %Entry{turn_id: "t", role: "assistant", content: "d"})

    assert {:ok, oe} = ETS.history(h, "s1")
    assert Enum.map(oe, & &1.content) == ["a", "b", "c"]
    assert {:ok, fe} = ETS.history(h, forked)
    assert Enum.map(fe, & &1.content) == ["a", "b", "d"]
  end

  test "turn state round-trips an opaque term; missing is :error", %{handle: h} do
    term = {:turn, %{step: 7}}
    assert :ok = ETS.save_turn_state(h, "s1", term)
    assert {:ok, ^term} = ETS.load_turn_state(h, "s1")
    assert :error = ETS.load_turn_state(h, "never")
  end

  test "implements the SessionStore behaviour" do
    behaviours = ETS.module_info(:attributes)[:behaviour] || []
    assert Normandy.Behaviours.SessionStore in behaviours
  end
end
