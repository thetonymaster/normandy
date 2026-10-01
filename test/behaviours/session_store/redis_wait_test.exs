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
    {:ok, store: Redis.new(wait: {1, 50})}
  end

  test "new/1 keeps the wait setting in the handle", %{store: store} do
    assert {_conn, _ns, {1, 50}} = store
  end

  test "an entry append fails when the replica wait is unmet", %{store: store} do
    assert {:error, {:wait_unmet, 0, 1}} =
             Redis.append_entry(store, "s1", %Entry{role: "user", content: "hi"})
  end

  test "turn state and template saves fail when the replica wait is unmet", %{store: store} do
    assert {:error, {:wait_unmet, 0, 1}} = Redis.save_turn_state(store, "s1", :state)
    assert {:error, {:wait_unmet, 0, 1}} = Redis.save_config_template(store, "s1", %{})
  end

  test "reads work with a wait handle", %{store: store} do
    assert {:ok, []} = Redis.history(store, "s1")
    assert :error = Redis.load_turn_state(store, "s1")
  end
end
