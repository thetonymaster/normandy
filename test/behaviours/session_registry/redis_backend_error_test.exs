defmodule Normandy.Behaviours.SessionRegistry.RedisBackendErrorTest do
  # No :redis tag: these tests need a connection that cannot reach Redis.
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionRegistry.Redis

  setup do
    # Port 1 refuses connections; without sync_connect every command fails with
    # a connection error instead of the start failing.
    conn =
      start_supervised!(
        {Redix, host: "127.0.0.1", port: 1, sync_connect: false, exit_on_disconnection: false}
      )

    name = :"redis_registry_down_#{System.unique_integer([:positive])}"
    {:ok, _} = Redis.start_link(name: name, conn: conn, namespace: "normandy-test-down")
    {:ok, owner: name}
  end

  test "whereis reports a connection failure as {:error, reason}, not as no session", ctx do
    assert {:error, %Redix.ConnectionError{}} = Redis.whereis(ctx.owner, "s1")
  end
end
