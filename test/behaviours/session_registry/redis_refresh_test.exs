defmodule Normandy.Behaviours.SessionRegistry.RedisRefreshTest do
  @moduledoc """
  PERF-6: `whereis/2` runs in the caller, the TTL refresh is one pipelined `EVALSHA`
  per chunk, and a registration found taken by another process is fenced: the local
  process stops with `{:shutdown, :registration_lost}` and
  `[:normandy, :session_registry, :ownership_lost]` is emitted. The refresh is
  triggered by sending `:refresh`; `:sys.get_state/1` waits for it to finish.
  """
  use ExUnit.Case, async: true
  @moduletag :redis
  @moduletag :capture_log

  alias Normandy.Behaviours.SessionRegistry.Redis
  alias Normandy.Test.TelemetryCapture

  import Normandy.Test.Eventually, only: [wait_until: 1]

  setup do
    handle = Redis.new()

    {:ok, raw} =
      Redix.start_link(Application.get_env(:normandy, :redis_url, "redis://localhost:6379"))

    {:ok, handle: handle, raw: raw}
  end

  defp key(handle, sid), do: "#{handle.namespace}:reg:{#{sid}}"

  defp sleeper do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp refresh(handle) do
    send(handle.owner, :refresh)
    :sys.get_state(handle.owner)
  end

  test "whereis does not wait on the owner", %{handle: handle} do
    pid = sleeper()
    :ok = Redis.register(handle, "s1", pid)
    :ok = :sys.suspend(handle.owner)

    assert Redis.whereis(handle, "s1") == {:ok, pid}
    assert Redis.whereis(handle, "s2") == :none

    :ok = :sys.resume(handle.owner)
  end

  test "a refresh extends the TTL of every key the owner holds", %{handle: h, raw: raw} do
    pids = for sid <- ["a", "b", "c"], into: %{}, do: {sid, sleeper()}
    for {sid, pid} <- pids, do: :ok = Redis.register(h, sid, pid)

    for sid <- ["a", "b", "c"],
        do: {:ok, 1} = Redix.command(raw, ["PEXPIRE", key(h, sid), "1000"])

    refresh(h)

    for sid <- ["a", "b", "c"] do
      {:ok, ttl} = Redix.command(raw, ["PTTL", key(h, sid)])
      assert ttl > 1_000, "#{sid}: PTTL #{ttl}"
    end
  end

  test "a refresh after the script cache was flushed reloads the script", %{
    handle: h,
    raw: raw
  } do
    :ok = Redis.register(h, "a", sleeper())
    {:ok, 1} = Redix.command(raw, ["PEXPIRE", key(h, "a"), "1000"])
    {:ok, "OK"} = Redix.command(raw, ["SCRIPT", "FLUSH"])

    refresh(h)

    {:ok, ttl} = Redix.command(raw, ["PTTL", key(h, "a")])
    assert ttl > 1_000
  end

  test "a key that lapsed is claimed again", %{handle: h, raw: raw} do
    pid = sleeper()
    :ok = Redis.register(h, "a", pid)
    {:ok, 1} = Redix.command(raw, ["DEL", key(h, "a")])

    refresh(h)

    assert Redis.whereis(h, "a") == {:ok, pid}
    assert Process.alive?(pid)
  end

  test "a key another process holds stops the local one and emits ownership_lost", %{
    handle: h,
    raw: raw
  } do
    pid = sleeper()
    other = sleeper()
    keep = sleeper()
    :ok = Redis.register(h, "taken", pid)
    :ok = Redis.register(h, "kept", keep)
    ref = Process.monitor(pid)

    tel =
      TelemetryCapture.attach([[:normandy, :session_registry, :ownership_lost]],
        registry: h.owner
      )

    {:ok, "OK"} = Redix.command(raw, ["SET", key(h, "taken"), :erlang.term_to_binary(other)])

    refresh(h)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :registration_lost}}

    assert_received {:telemetry, ^tel, %{count: 1}, %{session_id: "taken", registry: owner}}

    assert owner == h.owner
    refute_received {:telemetry, ^tel, _, %{session_id: "kept"}}
    assert Redis.whereis(h, "taken") == {:ok, other}
    assert Redis.whereis(h, "kept") == {:ok, keep}

    state = :sys.get_state(h.owner)
    refute Map.has_key?(state.sids, "taken")
    assert Map.has_key?(state.sids, "kept")
  end

  describe "an owner started with :url" do
    test "a handle fetched before the owner restarts still resolves a registered session" do
      name = :"redis_registry_restart_#{System.unique_integer([:positive])}"
      url = Application.get_env(:normandy, :redis_url, "redis://localhost:6379")
      ns = "normandy_reg_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: name,
        start: {Redis, :start_link, [[name: name, url: url, namespace: ns]]}
      })

      handle = Redis.fetch_handle(name)
      assert handle.conn == Module.concat(name, Redix)

      pid = sleeper()
      :ok = Redis.register(handle, "s1", pid)

      old_owner = Process.whereis(name)
      old_conn = GenServer.whereis(handle.conn)
      ref = Process.monitor(old_conn)
      Process.exit(old_owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_conn, _}

      assert wait_until(fn ->
               new_owner = Process.whereis(name)
               is_pid(new_owner) and new_owner != old_owner
             end)

      # init/1 has returned, so the new connection holds the name.
      _ = :sys.get_state(name)
      assert GenServer.whereis(handle.conn) not in [nil, old_conn]
      assert Redis.whereis(handle, "s1") == {:ok, pid}
      assert Redis.fetch_handle(name) == handle
    end

    test "an owner stopped normally and started again under its name takes the name back" do
      name = :"redis_registry_again_#{System.unique_integer([:positive])}"
      url = Application.get_env(:normandy, :redis_url, "redis://localhost:6379")

      opts = [
        name: name,
        url: url,
        namespace: "normandy_reg_#{System.unique_integer([:positive])}"
      ]

      {:ok, first} = Redis.start_link(opts)
      handle = Redis.fetch_handle(name)
      old_conn = GenServer.whereis(handle.conn)
      :ok = GenServer.stop(first)

      start_supervised!(%{id: name, start: {Redis, :start_link, [opts]}})

      refute Process.alive?(old_conn)
      pid = sleeper()
      :ok = Redis.register(handle, "s1", pid)
      assert Redis.whereis(handle, "s1") == {:ok, pid}
    end
  end
end
