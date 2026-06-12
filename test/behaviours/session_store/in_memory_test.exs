defmodule Normandy.Behaviours.SessionStore.InMemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory.Entry

  setup do
    {:ok, handle: InMemory.new()}
  end

  test "append_entry returns an id; history is chronological", %{handle: h} do
    {:ok, id1} = InMemory.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "a"})

    {:ok, id2} =
      InMemory.append_entry(h, "s1", %Entry{turn_id: "t", role: "assistant", content: "b"})

    assert is_binary(id1) and is_binary(id2)
    assert {:ok, entries} = InMemory.history(h, "s1")
    assert Enum.map(entries, & &1.content) == ["a", "b"]
  end

  test "history on an unknown session is empty", %{handle: h} do
    assert {:ok, []} = InMemory.history(h, "missing")
  end

  test "fork yields the ancestor chain and isolates appends", %{handle: h} do
    {:ok, _} = InMemory.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "a"})

    {:ok, at} =
      InMemory.append_entry(h, "s1", %Entry{turn_id: "t", role: "assistant", content: "b"})

    {:ok, _} = InMemory.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "c"})

    {:ok, forked} = InMemory.fork(h, "s1", at)
    assert {:ok, fe} = InMemory.history(h, forked)
    assert Enum.map(fe, & &1.content) == ["a", "b"]

    {:ok, _} =
      InMemory.append_entry(h, forked, %Entry{turn_id: "t", role: "assistant", content: "d"})

    assert {:ok, oe} = InMemory.history(h, "s1")
    assert Enum.map(oe, & &1.content) == ["a", "b", "c"]
    assert {:ok, fe2} = InMemory.history(h, forked)
    assert Enum.map(fe2, & &1.content) == ["a", "b", "d"]
  end

  test "turn state round-trips an opaque term; missing is :error", %{handle: h} do
    term = {:turn, %{step: 3}, "opaque"}
    assert :ok = InMemory.save_turn_state(h, "s1", term)
    assert {:ok, ^term} = InMemory.load_turn_state(h, "s1")
    assert :error = InMemory.load_turn_state(h, "never")
  end

  test "implements the SessionStore behaviour" do
    behaviours = InMemory.module_info(:attributes)[:behaviour] || []
    assert Normandy.Behaviours.SessionStore in behaviours
  end
end
