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
end
