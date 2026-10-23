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

defmodule Normandy.Behaviours.SessionStore.RedisWaitConfigTest do
  # async: false — one test sets the :redis_wait app env.
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.SessionStore.Redis

  # WAIT with a 0 timeout blocks until the replicas answer, possibly forever, and
  # the connection is shared: every later command would queue behind it.
  test "new/1 rejects a replica wait with no timeout" do
    assert_raise ArgumentError, ~r/:wait .* timeout_ms must be positive/, fn ->
      Redis.new(wait: {1, 0})
    end
  end

  test "new/1 refuses :wait_connections without a replica wait" do
    assert_raise ArgumentError,
                 "Normandy.Behaviours.SessionStore.Redis.new/1: :wait_connections needs a " <>
                   ":wait of one replica or more, got: no :wait",
                 fn -> Redis.new(wait_connections: 2) end

    assert_raise ArgumentError,
                 "Normandy.Behaviours.SessionStore.Redis.new/1: :wait_connections needs a " <>
                   ":wait of one replica or more, got: a :wait of 0 replicas",
                 fn -> Redis.new(wait: {0, 10}, wait_connections: 2) end
  end

  test "a handle whose wait connections are not a non-empty tuple raises on the write" do
    assert_raise ArgumentError,
                 "Normandy.Behaviours.SessionStore.Redis: the handle's wait_conns must be a " <>
                   "non-empty tuple of Redix connections, got: a list",
                 fn ->
                   Redis.save_turn_state(
                     Normandy.Test.opaque({:c, "ns", {1, 10}, [:c]}),
                     "s1",
                     :ts,
                     false
                   )
                 end
  end

  test "a :redis_wait app env with replicas and no timeout raises on the write" do
    previous = Application.fetch_env(:normandy, :redis_wait)
    Application.put_env(:normandy, :redis_wait, {1, 0})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:normandy, :redis_wait, value)
        :error -> Application.delete_env(:normandy, :redis_wait)
      end
    end)

    conn =
      start_supervised!(
        {Redix, host: "127.0.0.1", port: 1, sync_connect: false, exit_on_disconnection: false}
      )

    assert_raise ArgumentError, ~r/:redis_wait .* timeout_ms must be positive/, fn ->
      Redis.save_turn_state({conn, "normandy-test-wait"}, "s1", :ts, false)
    end
  end
end
