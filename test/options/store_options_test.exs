defmodule Normandy.Options.StoreOptionsTest do
  use ExUnit.Case, async: true

  import Normandy.Test.OptionsAssertions

  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.MemoryStore.ETS, as: EtsMem
  alias Normandy.Behaviours.MemoryStore.InMemory, as: InMemoryMem
  alias Normandy.Behaviours.MemoryStore.Mnesia, as: MnesiaMem
  alias Normandy.Behaviours.MemoryStore.Redis, as: RedisMem
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HordeReg
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionRegistry.Redis, as: RedisReg
  alias Normandy.Behaviours.SessionStore.ETS, as: EtsStore
  alias Normandy.Behaviours.SessionStore.InMemory, as: InMemoryStore
  alias Normandy.Behaviours.SessionStore.Mnesia, as: MnesiaStore
  alias Normandy.Behaviours.SessionStore.Redis, as: RedisStore
  alias Normandy.Cluster

  # Each call raises before it starts a process, connects to Redis or touches Mnesia.
  @cases [
    {:nam, {Native, :start_link, [[nam: :x]]}},
    {:nam, {Native, :new, [[nam: :x]]}},
    {:nam, {HordeReg, :start_link, [[nam: :x]]}},
    {:nam, {HordeReg, :new, [[nam: :x]]}},
    {:namespce, {RedisReg, :new, [[namespce: "n"]]}},
    {:ttl, {RedisReg, :start_link, [[ttl: 1]]}},
    {:ownr, {RedisReg, :handle, [[ownr: :x]]}},
    {:name, {InMemoryStore, :start_link, [[name: :x]]}},
    {:name, {InMemoryStore, :new, [[name: :x]]}},
    {:nam, {EtsStore, :start_link, [[nam: :x]]}},
    {:nam, {EtsStore, :new, [[nam: :x]]}},
    {:entires, {MnesiaStore, :new, [[entires: :x]]}},
    {:copys, {MnesiaStore, :create_tables, [[copys: :ram_copies]]}},
    {:wiat, {RedisStore, :new, [[wiat: {0, 0}]]}},
    {:name, {InMemoryMem, :new, [[name: :x]]}},
    {:name, {EtsMem, :new, [[name: :x]]}},
    {:tabel, {MnesiaMem, :new, [[tabel: :x]]}},
    {:tabel, {MnesiaMem, :create_tables, [[tabel: :x]]}},
    {:prefx, {RedisMem, :new, [[prefx: "p"]]}},
    {:templats, {Catalog, :start_link, [[templats: %{}]]}},
    {:topologys, {Cluster, :child_specs, [[topologys: []]]}},
    {:namespce, {Cluster, :redis_child_specs, [[namespce: "n"]]}},
    {:namespce, {Cluster, :redis_handles, [[namespce: "n"]]}},
    {:copys, {Cluster, :setup_mnesia_store!, [[copys: :ram_copies]]}}
  ]

  for {key, {mod, fun, args}} <- @cases do
    test "#{inspect(mod)}.#{fun}/#{length(args)} rejects #{inspect(key)}" do
      assert_rejects(unquote(key), unquote(mod), unquote(fun), unquote(Macro.escape(args)))
    end
  end

  test "every entry point documents its options" do
    for {_key, {mod, fun, args}} <- @cases, do: assert_documents_options(mod, fun, length(args))
  end

  test "SessionRegistry.Redis.start_link/1 needs :conn or :url" do
    error =
      assert_raise ArgumentError, fn -> RedisReg.start_link(name: :reg_x, namespace: "n") end

    assert error.message ==
             "Normandy.Behaviours.SessionRegistry.Redis.start_link/1: requires :conn (a Redix " <>
               "connection) or :url"
  end

  test "SessionRegistry.Redis.start_link/1 rejects conn: nil" do
    error =
      assert_raise ArgumentError, fn ->
        RedisReg.start_link(name: :reg_x, namespace: "n", conn: nil)
      end

    assert error.message ==
             "Normandy.Behaviours.SessionRegistry.Redis.start_link/1: invalid value for :conn " <>
               "option: expected a Redix connection (a pid or a registered name), got: nil"
  end

  test ":url, :redix, :store_redix and :templates are sensitive keys" do
    for key <- [:url, :redix, :store_redix, :templates],
        do: assert(key in Normandy.Options.sensitive_keys())
  end

  # Each value is a wrong-type scalar whose text holds a secret: NimbleOptions would echo it,
  # so only the sensitive-key redaction hides it and shows the option's :type_doc instead.
  @redaction_cases [
    {:url, "`t:String.t/0`", {RedisReg, :new, [[url: :"redis://:sk-secret@h"]]}},
    {:redix, "`t:keyword/0`",
     {Cluster, :redis_child_specs,
      [[redix: :"sk-secret", namespace: "n", registry: :r, supervisor: :s]]}},
    {:store_redix, "`t:keyword/0`",
     {Cluster, :redis_child_specs,
      [
        [
          store_redix: :"sk-secret",
          redix: [name: :r],
          namespace: "n",
          registry: :r,
          supervisor: :s
        ]
      ]}},
    {:templates, "`t:map/0`", {Catalog, :start_link, [[templates: :"sk-secret"]]}}
  ]

  for {key, type_doc, {mod, fun, args}} <- @redaction_cases do
    test "a bad #{inspect(key)} value is not echoed; its type_doc is shown" do
      error =
        assert_rejects(unquote(key), unquote(mod), unquote(fun), unquote(Macro.escape(args)))

      assert error.message =~ "invalid value for #{inspect(unquote(key))} option"
      assert error.message =~ "expected #{unquote(type_doc)}", error.message
      refute error.message =~ "sk-secret"
    end
  end

  test "Cluster.redis_child_specs/1 names a :redix list without :name" do
    error =
      assert_raise ArgumentError, fn ->
        Cluster.redis_child_specs(
          redix: [host: "h"],
          namespace: "n",
          registry: :r,
          supervisor: :s
        )
      end

    assert error.message ==
             "Normandy.Cluster.redis_child_specs/1: :redix must include :name, the Redix " <>
               "connection's registered name"
  end

  test "Cluster.redis_handles/1 names a :redix list without :name" do
    error =
      assert_raise ArgumentError, fn ->
        Cluster.redis_handles(redix: [host: "h"], namespace: "n", registry: :r, supervisor: :s)
      end

    assert error.message ==
             "Normandy.Cluster.redis_handles/1: :redix must include :name, the Redix " <>
               "connection's registered name"
  end
end
