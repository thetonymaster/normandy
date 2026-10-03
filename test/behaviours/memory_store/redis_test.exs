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

  test "a rename racing a write leaves no orphaned document hash", %{handle: {conn, prefix} = h} do
    for round <- 1..20 do
      ns = "race-#{round}-#{System.unique_integer([:positive])}"
      {:ok, _} = Redis.put(h, ns, "/memories/a/doc", "x", :new)

      [
        Task.async(fn -> Redis.rename(h, ns, "/memories/a", "/memories/b") end),
        Task.async(fn -> Redis.put(h, ns, "/memories/a/doc", "y", :any) end)
      ]
      |> Enum.each(&Task.await(&1, 5_000))

      # the key layout of Redis.idx/2 and Redis.doc_prefix/2
      tag = "#{prefix}:mem:{#{Base.url_encode64(ns, padding: false)}}"
      {:ok, indexed} = Redix.command(conn, ["ZCARD", tag <> ":idx"])
      hashes = scan(conn, tag <> ":doc:*", "0", [])
      # a stale key layout would find nothing and pass vacuously
      assert indexed >= 1
      assert length(hashes) == indexed, "round #{round}: #{inspect(hashes)} vs #{indexed} indexed"
    end
  end

  defp scan(conn, pattern, cursor, acc) do
    {:ok, [next, keys]} = Redix.command(conn, ["SCAN", cursor, "MATCH", pattern, "COUNT", "1000"])
    if next == "0", do: Enum.uniq(acc ++ keys), else: scan(conn, pattern, next, acc ++ keys)
  end
end
