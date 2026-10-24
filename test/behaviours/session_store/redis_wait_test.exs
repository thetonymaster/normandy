defmodule Normandy.Behaviours.SessionStore.RedisWaitTest do
  @moduledoc """
  `wait: {numreplicas, timeout_ms}` makes writes fail when Redis does not
  confirm them on that many replicas. The test Redis has no replicas, so a
  wait for one is never met.
  """
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Behaviours.SessionStore.Redis
  alias Normandy.Components.AgentMemory.Entry

  setup do
    {:ok, store: Normandy.TestHandles.redis_session_store(wait: {1, 50})}
  end

  test "new/1 keeps the wait setting and its wait connections in the handle", %{store: store} do
    assert {conn, _ns, {1, 50}, wait_conns} = store
    assert tuple_size(wait_conns) == 4
    refute conn in Tuple.to_list(wait_conns)

    assert {_conn, _ns, {1, 50}, {_one}} =
             Normandy.TestHandles.redis_session_store(wait: {1, 50}, wait_connections: 1)
  end

  test "a wait of 0 replicas opens no wait connections" do
    assert {_conn, _ns, {0, 0}} = Normandy.TestHandles.redis_session_store(wait: {0, 0})
  end

  test "an entry append fails when the replica wait is unmet", %{store: store} do
    assert {:error, {:wait_unmet, 0, 1}} =
             Redis.append_entry(store, "s1", %Entry{role: "user", content: "hi"})
  end

  test "turn state and template saves fail when the replica wait is unmet", %{store: store} do
    assert {:error, {:wait_unmet, 0, 1}} = Redis.save_turn_state(store, "s1", :state, false)
    assert {:error, {:wait_unmet, 0, 1}} = Redis.save_config_template(store, "s1", %{})
  end

  test "reads work with a wait handle", %{store: store} do
    assert {:ok, []} = Redis.history(store, "s1")
    assert :error = Redis.load_turn_state(store, "s1")
  end
end
