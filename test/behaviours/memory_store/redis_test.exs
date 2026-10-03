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
end
