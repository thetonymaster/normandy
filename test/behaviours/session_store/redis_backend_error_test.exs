defmodule Normandy.Behaviours.SessionStore.RedisBackendErrorTest do
  # No :redis tag: these tests need a connection that cannot reach Redis.
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore.Redis

  setup do
    # Port 1 refuses connections; without sync_connect every command fails with
    # a connection error instead of the start failing.
    conn =
      start_supervised!(
        {Redix, host: "127.0.0.1", port: 1, sync_connect: false, exit_on_disconnection: false}
      )

    {:ok, store: {conn, "normandy-test-#{System.unique_integer([:positive])}"}}
  end

  test "load_turn_state reports a connection failure as {:error, reason}", %{store: store} do
    assert {:error, %Redix.ConnectionError{}} = Redis.load_turn_state(store, "s1")
  end

  test "load_config_template reports a connection failure as {:error, reason}", %{store: store} do
    assert {:error, %Redix.ConnectionError{}} = Redis.load_config_template(store, "s1")
  end
end
