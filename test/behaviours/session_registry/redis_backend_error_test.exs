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
    {:ok, handle: Redis.handle(owner: name, conn: conn, namespace: "normandy-test-down")}
  end

  test "whereis reports a connection failure as {:error, reason}, not as no session", ctx do
    assert {:error, %Redix.ConnectionError{}} = Redis.whereis(ctx.handle, "s1")
  end

  test "whereis runs in the caller: a suspended owner does not hold it", ctx do
    :ok = :sys.suspend(ctx.handle.owner)

    assert {:error, %Redix.ConnectionError{}} = Redis.whereis(ctx.handle, "s1")

    :ok = :sys.resume(ctx.handle.owner)
  end

  test "whereis on a stopped connection is {:error, _}, not an exit", ctx do
    :ok = stop_supervised(Redix)

    assert {:error, {:exit, :redix_exited_during_call}} = Redis.whereis(ctx.handle, "s1")

    named = %{ctx.handle | conn: :normandy_no_such_redix}
    assert {:error, :noproc} = Redis.whereis(named, "s1")
  end

  test "a 1.x handle (the owner's name) raises, naming the handle struct", ctx do
    assert_raise ArgumentError,
                 "Normandy.Behaviours.SessionRegistry.Redis.whereis/2: expected a " <>
                   "%Normandy.Behaviours.SessionRegistry.Redis.Handle{} (build it with " <>
                   "Normandy.Behaviours.SessionRegistry.Redis.handle/1), got: " <>
                   inspect(ctx.handle.owner),
                 fn -> Redis.whereis(ctx.handle.owner, "s1") end
  end
end
