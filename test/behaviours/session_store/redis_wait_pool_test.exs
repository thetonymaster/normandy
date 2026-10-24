defmodule Normandy.Behaviours.SessionStore.RedisWaitPoolTest do
  @moduledoc """
  PERF-12: a waited write and its `WAIT` run on one of the handle's wait connections,
  chosen by session id, so a `WAIT` blocks neither the store's main connection nor the
  other wait connections. The test Redis has no replica, so `WAIT 1 60000` blocks until
  `CLIENT UNBLOCK` releases it; `CLIENT LIST ID` shows when it is blocked. No sleeps.
  """
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Behaviours.SessionStore.Redis
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Test.Eventually

  setup do
    {:ok, raw} =
      Redix.start_link(Normandy.TestHandles.redis_url())

    {:ok, raw: raw}
  end

  defp client_id(conn) do
    {:ok, id} = Redix.command(conn, ["CLIENT", "ID"])
    Integer.to_string(id)
  end

  # Blocked now (flag b) in a WAIT (cmd is the client's last command, so it alone stays
  # "wait" after the client is released).
  defp blocked_in_wait?(raw, id) do
    {:ok, line} = Redix.command(raw, ["CLIENT", "LIST", "ID", id])
    line =~ ~r/ flags=[A-Za-z]*b/ and line =~ " cmd=wait "
  end

  # The session ids that land on wait connection 0 and on wait connection 1 of 2.
  defp sessions_on_each_conn do
    ids = Enum.map(1..50, &"s#{&1}")
    {Enum.find(ids, &(:erlang.phash2(&1, 2) == 0)), Enum.find(ids, &(:erlang.phash2(&1, 2) == 1))}
  end

  test "a blocked WAIT holds neither reads nor another session's wait connection", %{raw: raw} do
    {conn, _ns, {1, 60_000}, {wait0, wait1}} =
      store = Normandy.TestHandles.redis_session_store(wait: {1, 60_000}, wait_connections: 2)

    {blocked_sid, other_sid} = sessions_on_each_conn()
    id0 = client_id(wait0)
    id1 = client_id(wait1)

    task =
      Task.async(fn ->
        Redis.append_entry(store, blocked_sid, %Entry{role: "user", content: "a"})
      end)

    assert Eventually.wait_until(fn -> blocked_in_wait?(raw, id0) end)

    # The main connection answers while the WAIT holds wait connection 0.
    assert {:ok, [%Entry{content: "a"}]} = Redis.history(store, blocked_sid)
    assert {:ok, "PONG"} = Redix.command(conn, ["PING"])
    # So does wait connection 1: another session's write is not queued behind it.
    assert {:ok, "PONG"} = Redix.command(wait1, ["PING"])
    refute blocked_in_wait?(raw, id1)
    assert Task.yield(task, 0) == nil

    assert {:ok, 1} = Redix.command(raw, ["CLIENT", "UNBLOCK", id0])
    assert Task.await(task) == {:error, {:wait_unmet, 0, 1}}

    other =
      Task.async(fn -> Redis.save_turn_state(store, other_sid, :ts, false) end)

    assert Eventually.wait_until(fn -> blocked_in_wait?(raw, id1) end)
    refute blocked_in_wait?(raw, id0)
    assert {:ok, 1} = Redix.command(raw, ["CLIENT", "UNBLOCK", id1])
    assert Task.await(other) == {:error, {:wait_unmet, 0, 1}}
  end

  test "one session's waited writes always use the same wait connection", %{raw: raw} do
    {_conn, _ns, {1, 60_000}, wait_conns} =
      store = Normandy.TestHandles.redis_session_store(wait: {1, 60_000}, wait_connections: 3)

    expected = elem(wait_conns, :erlang.phash2("s-same", 3))
    id = client_id(expected)

    for write <- [
          fn -> Redis.append_entry(store, "s-same", %Entry{role: "user", content: "a"}) end,
          fn -> Redis.save_turn_state(store, "s-same", :ts, false) end,
          fn -> Redis.save_config_template(store, "s-same", %{}) end
        ] do
      task = Task.async(write)
      assert Eventually.wait_until(fn -> blocked_in_wait?(raw, id) end)
      assert {:ok, 1} = Redix.command(raw, ["CLIENT", "UNBLOCK", id])
      assert Task.await(task) == {:error, {:wait_unmet, 0, 1}}
    end
  end

  test "every waited write runs wholly on the session's wait connection, never on conn" do
    url = Normandy.TestHandles.redis_url()
    {:ok, dead} = Redix.start_link(url)
    Process.unlink(dead)
    ref = Process.monitor(dead)
    :ok = GenServer.stop(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    {_conn, ns, wait, wait_conns} =
      Normandy.TestHandles.redis_session_store(wait: {1, 50}, wait_connections: 2)

    store = {dead, ns, wait, wait_conns}

    # No replica: each write reaches its WAIT on a wait connection and finds it unmet. A
    # write sent to the dead main connection would exit instead.
    for write <- [
          fn -> Redis.append_entry(store, "s-w", %Entry{role: "user", content: "a"}) end,
          fn -> Redis.save_turn_state(store, "s-w", :ts, false) end,
          fn -> Redis.save_config_template(store, "s-w", %{}) end,
          fn -> Redis.delete_session(store, "s-w") end
        ] do
      assert write.() == {:error, {:wait_unmet, 0, 1}}
    end
  end
end
