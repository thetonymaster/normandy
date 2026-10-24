defmodule Normandy.ClusterRedisWaitTest do
  @moduledoc """
  PERF-12: when `config :normandy, :redis_wait` asks for replicas, the Redis combo starts
  a pool of Redix connections for the store's waited writes and builds the store handle
  on it; `:store_redix` gives the store its own connection instead. Pure: the specs and
  handles are built, nothing is started.
  """
  # async: false — sets the :redis_wait app env.
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.SessionStore.Redis, as: RedisStore
  alias Normandy.Cluster

  @combo [
    redix: [name: :combo_redix, host: "localhost", port: 6379],
    namespace: "combo",
    registry: :combo_reg,
    supervisor: :combo_sup
  ]

  setup do
    previous = Application.fetch_env(:normandy, :redis_wait)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:normandy, :redis_wait, value)
        :error -> Application.delete_env(:normandy, :redis_wait)
      end
    end)
  end

  defp redix_specs(specs) do
    for %{id: id, start: {Redix, :start_link, [opts]}} <-
          Enum.map(specs, &Supervisor.child_spec(&1, [])),
        do: {id, opts}
  end

  test "without replicas: one connection, shared, and a {conn, namespace} store" do
    Application.put_env(:normandy, :redis_wait, {0, 0})

    assert [{Redix, [name: :combo_redix, host: "localhost", port: 6379]}] =
             redix_specs(Cluster.redis_child_specs(@combo))

    assert Cluster.redis_handles(@combo).store == {RedisStore, {:combo_redix, "combo"}}
  end

  test "with replicas: a pool of :wait_connections named after :redix, in the store handle" do
    Application.put_env(:normandy, :redis_wait, {1, 100})
    pool = [:"combo_redix.wait.0", :"combo_redix.wait.1"]
    opts = Keyword.put(@combo, :wait_connections, 2)

    assert [{Redix, _} | waits] = redix_specs(Cluster.redis_child_specs(opts))

    assert waits == Enum.map(pool, &{&1, [name: &1, host: "localhost", port: 6379]})

    assert Cluster.redis_handles(opts).store ==
             {RedisStore, {:combo_redix, "combo", {1, 100}, List.to_tuple(pool)}}

    assert {RedisStore, {_conn, _ns, {1, 100}, default_pool}} =
             Cluster.redis_handles(@combo).store

    assert tuple_size(default_pool) == 4
  end

  test ":store_redix gives the store its own connection and starts no pool" do
    Application.put_env(:normandy, :redis_wait, {1, 100})
    opts = Keyword.put(@combo, :store_redix, name: :combo_store_redix, host: "h2")

    assert [
             {Redix, [name: :combo_redix, host: "localhost", port: 6379]},
             {:store_redix, [name: :combo_store_redix, host: "h2"]}
           ] =
             redix_specs(Cluster.redis_child_specs(opts))

    assert Cluster.redis_handles(opts).store ==
             {RedisStore, {:combo_store_redix, "combo", {1, 100}}}

    Application.put_env(:normandy, :redis_wait, {0, 0})
    assert Cluster.redis_handles(opts).store == {RedisStore, {:combo_store_redix, "combo"}}
  end

  test ":store_redix and :wait_connections together raise" do
    opts = @combo ++ [store_redix: [name: :s], wait_connections: 2]

    assert_raise ArgumentError,
                 "Normandy.Cluster.redis_child_specs/1: :wait_connections and :store_redix " <>
                   "exclude each other (with :store_redix, waited writes run on that connection)",
                 fn -> Cluster.redis_child_specs(opts) end
  end

  # Final review M-f: SessionStore.Redis.new/1 refuses :wait_connections without a wait;
  # the combo ignored it, so a host never learned its writes were not waited.
  test ":wait_connections without replicas in :redis_wait raises in both entry points" do
    Application.put_env(:normandy, :redis_wait, {0, 0})
    opts = Keyword.put(@combo, :wait_connections, 2)

    for fun <- [:redis_child_specs, :redis_handles] do
      assert_raise ArgumentError,
                   "Normandy.Cluster.#{fun}/1: :wait_connections needs config :normandy, " <>
                     ":redis_wait to ask for one replica or more, got 0 replicas",
                   fn -> apply(Cluster, fun, [opts]) end
    end
  end

  test "a pool needs an atom :redix name" do
    Application.put_env(:normandy, :redis_wait, {1, 100})
    opts = Keyword.put(@combo, :redix, name: {:global, :combo}, host: "h")

    assert_raise ArgumentError,
                 "Normandy.Cluster.redis_handles/1: with config :normandy, :redis_wait, the " <>
                   ":redix :name must be an atom (the WAIT pool is named after it), got: a tuple",
                 fn -> Cluster.redis_handles(opts) end
  end
end
