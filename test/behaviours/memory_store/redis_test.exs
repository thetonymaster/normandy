defmodule Normandy.Behaviours.MemoryStore.RedisTest do
  use ExUnit.Case, async: true
  @moduletag :redis
  alias Normandy.Behaviours.MemoryStore.Redis

  use Normandy.MemoryStoreContract, impl: Redis

  test "a script missing from the server cache is reloaded (NOSCRIPT fallback)", %{
    handle: {conn, _} = h,
    ns: ns
  } do
    {:ok, "OK"} = Redix.command(conn, ["SCRIPT", "FLUSH"])
    assert {:ok, 1} = Redis.put(h, ns, "/memories/a", "x", :new)
  end

  test "namespaces containing } cannot collide with each other's keys", %{handle: h} do
    ns1 = "a"
    ns2 = "a}:doc:/memories/p"
    assert {:ok, 1} = Redis.put(h, ns1, "/memories/p}:doc:/memories/q", "one", :new)
    assert {:ok, 1} = Redis.put(h, ns2, "/memories/q", "two", :new)

    assert {:ok, %{content: "one"}} = Redis.get(h, ns1, "/memories/p}:doc:/memories/q")
    assert {:ok, %{content: "two"}} = Redis.get(h, ns2, "/memories/q")
    assert :not_found = Redis.get(h, ns1, "/memories/q")
  end

  test "a namespace starting with } works", %{handle: h} do
    assert {:ok, 1} = Redis.put(h, "}x", "/memories/a", "v", :new)
    assert {:ok, %{content: "v"}} = Redis.get(h, "}x", "/memories/a")
    assert {:ok, [%{path: "/memories/a"}]} = Redis.list(h, "}x", "/memories")
  end
end
