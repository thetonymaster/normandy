defmodule Normandy.Behaviours.SessionStore.RedisStoreExtraTest do
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Behaviours.SessionStore.Redis
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry

  setup do
    {:ok, handle: Redis.new()}
  end

  defp e(role, content), do: %Entry{turn_id: "t", role: role, content: content}

  test "fork copies the prefix into a new stream and stays isolated", %{handle: h} do
    {:ok, _} = Redis.append_entry(h, "s1", e("user", "a"))
    {:ok, at} = Redis.append_entry(h, "s1", e("assistant", "b"))
    {:ok, _} = Redis.append_entry(h, "s1", e("user", "c"))

    {:ok, forked} = Redis.fork(h, "s1", at)
    {:ok, fe} = Redis.history(h, forked)
    assert Enum.map(fe, & &1.content) == ["a", "b"]

    {:ok, _} = Redis.append_entry(h, forked, e("assistant", "d"))
    {:ok, oe} = Redis.history(h, "s1")
    assert Enum.map(oe, & &1.content) == ["a", "b", "c"]
    {:ok, fe2} = Redis.history(h, forked)
    assert Enum.map(fe2, & &1.content) == ["a", "b", "d"]
  end

  test "WAIT with numreplicas: 0 is a no-op and save succeeds", %{handle: h} do
    # Default wait config {0,0} → no-op; boundary write returns :ok against single Redis.
    assert :ok = Redis.save_turn_state(h, "s1", %{step: 1})
    assert {:ok, %{step: 1}} = Redis.load_turn_state(h, "s1")
  end

  test "history round-trips through AgentMemory.from_entries preserving the full chain", %{
    handle: h
  } do
    {:ok, _} = Redis.append_entry(h, "s1", e("user", "a"))
    {:ok, _} = Redis.append_entry(h, "s1", e("assistant", "b"))
    {:ok, _} = Redis.append_entry(h, "s1", e("user", "c"))

    {:ok, entries} = Redis.history(h, "s1")
    rebuilt = entries |> AgentMemory.from_entries() |> AgentMemory.entry_chain()
    assert Enum.map(rebuilt, & &1.content) == ["a", "b", "c"]
  end

  test "forked-stream history round-trips through AgentMemory preserving the full chain", %{
    handle: h
  } do
    {:ok, _} = Redis.append_entry(h, "s1", e("user", "a"))
    {:ok, at} = Redis.append_entry(h, "s1", e("assistant", "b"))
    {:ok, _} = Redis.append_entry(h, "s1", e("user", "c"))
    {:ok, forked} = Redis.fork(h, "s1", at)
    {:ok, _} = Redis.append_entry(h, forked, e("assistant", "d"))

    {:ok, entries} = Redis.history(h, forked)
    rebuilt = entries |> AgentMemory.from_entries() |> AgentMemory.entry_chain()
    assert Enum.map(rebuilt, & &1.content) == ["a", "b", "d"]
  end

  test "history returns the id an entry was appended with; stream id when none", %{handle: h} do
    {:ok, _} = Redis.append_entry(h, "s-ids", %{e("user", "a") | id: "mem-1"})
    {:ok, stream_id} = Redis.append_entry(h, "s-ids", e("assistant", "b"))

    {:ok, [first, second]} = Redis.history(h, "s-ids")
    assert first.id == "mem-1"
    assert second.id == stream_id
    assert second.parent_id == "mem-1"
  end

  test "append_entry returns the id history will return: the entry's id, else the stream id",
       %{handle: h} do
    assert {:ok, "mem-1"} = Redis.append_entry(h, "s-ret", %{e("user", "a") | id: "mem-1"})
    assert {:ok, stream_id} = Redis.append_entry(h, "s-ret", e("assistant", "b"))

    {:ok, [first, second]} = Redis.history(h, "s-ret")
    assert first.id == "mem-1"
    assert second.id == stream_id
  end

  test "fork with a blank or nil target is :no_such_entry, even when an entry has no id field",
       %{handle: h} do
    {:ok, _} = Redis.append_entry(h, "s-blank", e("user", "a"))

    assert {:error, :no_such_entry} = Redis.fork(h, "s-blank", "")
    assert {:error, :no_such_entry} = Redis.fork(h, "s-blank", nil)
  end

  test "fork accepts the id history returned", %{handle: h} do
    {:ok, _} = Redis.append_entry(h, "s-fork-ids", %{e("user", "a") | id: "mem-1"})
    {:ok, _} = Redis.append_entry(h, "s-fork-ids", %{e("assistant", "b") | id: "mem-2"})
    {:ok, _} = Redis.append_entry(h, "s-fork-ids", %{e("user", "c") | id: "mem-3"})

    {:ok, forked} = Redis.fork(h, "s-fork-ids", "mem-2")
    {:ok, entries} = Redis.history(h, forked)
    assert Enum.map(entries, &{&1.id, &1.content}) == [{"mem-1", "a"}, {"mem-2", "b"}]
  end

  test "two forks of one session get distinct UUID ids", %{handle: h} do
    {:ok, at} = Redis.append_entry(h, "s-uuid", e("user", "a"))

    {:ok, first} = Redis.fork(h, "s-uuid", at)
    {:ok, second} = Redis.fork(h, "s-uuid", at)

    assert first != second
    assert {:ok, _} = UUID.info(first)
    assert {:ok, _} = UUID.info(second)
  end

  test "fork copies a prefix longer than one pipeline chunk, in order", %{handle: h} do
    ids = for n <- 1..1_001, do: elem(Redis.append_entry(h, "s-long", e("user", n)), 1)

    {:ok, forked} = Redis.fork(h, "s-long", List.last(ids))
    {:ok, entries} = Redis.history(h, forked)

    assert Enum.map(entries, & &1.content) == Enum.to_list(1..1_001)
  end
end
