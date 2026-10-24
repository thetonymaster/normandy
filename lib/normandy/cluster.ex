defmodule Normandy.Cluster do
  @moduledoc """
  Optional convenience for wiring the distributed-session infra (Tier 2) into a
  host supervision tree. Returns child specs for:

    * the Horde **registry** (`SessionRegistry.Horde`, `members: :auto`),
    * the Horde **supervisor** (`Turn.Supervisor.Horde`, `members: :auto`),
    * the **`Turn.ResumeReaper`** (only when both `:store` and `:template_provider`
      are supplied — eager handoff needs them), and
    * an optional `libcluster` `Cluster.Supervisor` (only when `:topologies` is
      given AND `libcluster` is a dependency of the *host* app).

  Cluster formation remains the host's choice — this is sugar, not a requirement.
  Normandy does NOT depend on `libcluster`; the `Cluster.Supervisor` spec is added
  only if the running system has it loaded (a runtime check), so hosts that wire
  their own clustering (or none) are unaffected.

  ## Example (host `application.ex`)

      children = [
        MyApp.Repo,
        {Normandy.Behaviours.AgentTemplate.Catalog, name: MyApp.AgentTemplates}
      ] ++
        Normandy.Cluster.child_specs(
          registry: MyApp.SessionRegistry,
          supervisor: MyApp.TurnSupervisor,
          store: {Normandy.Behaviours.SessionStore.Postgres, MyApp.Repo},
          template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, MyApp.AgentTemplates},
          topologies: Application.get_env(:libcluster, :topologies, [])
        )

      Supervisor.start_link(children, strategy: :one_for_one)
  """
  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Agents.Turn.Supervisor, as: LocalSup
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Behaviours.SessionRegistry.Redis, as: RedisReg
  alias Normandy.Behaviours.SessionStore.Mnesia, as: MnesiaStore
  alias Normandy.Behaviours.SessionStore.Redis, as: RedisStore
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Options

  # :store and :template_provider go to Turn.ResumeReaper, which takes them with the types
  # Turn.Session.new/1 gives them (ruling P4), so a bad value raises here, in the caller.
  @session_types Normandy.Agents.Turn.Session.Options.types()

  @child_specs_opts_schema NimbleOptions.new!(
                             registry: [
                               type: :atom,
                               required: true,
                               doc: "The Horde registry's name."
                             ],
                             supervisor: [
                               type: :atom,
                               required: true,
                               doc: "The Horde supervisor's name."
                             ],
                             store: [
                               type: @session_types.store,
                               type_doc: "`{module, handle}`",
                               doc:
                                 "The `SessionStore`; with `:template_provider`, starts the reaper."
                             ],
                             template_provider: [
                               type: @session_types.template_provider,
                               type_doc: "`{module, handle}`",
                               doc: "The `AgentTemplate`; with `:store`, starts the reaper."
                             ],
                             topologies: [
                               type: :keyword_list,
                               default: [],
                               doc:
                                 "libcluster topologies; adds `Cluster.Supervisor` when libcluster " <>
                                   "is loaded."
                             ]
                           )

  @redis_child_specs_opts_schema NimbleOptions.new!(
                                   redix: [
                                     type: :keyword_list,
                                     type_doc: "`t:keyword/0`",
                                     required: true,
                                     doc:
                                       "Options for the Redix connection; must include `:name`."
                                   ],
                                   namespace: [
                                     type: :string,
                                     required: true,
                                     doc: "The key namespace for the registry and the store."
                                   ],
                                   registry: [
                                     type: :atom,
                                     required: true,
                                     doc: "The Redis registry owner's name."
                                   ],
                                   supervisor: [
                                     type: :atom,
                                     required: true,
                                     doc: "The local `Turn.Supervisor`'s name."
                                   ],
                                   template_provider: [
                                     type: @session_types.template_provider,
                                     type_doc: "`{module, handle}`",
                                     doc: "The `AgentTemplate`; starts the reaper."
                                   ],
                                   store_redix: [
                                     type: :keyword_list,
                                     type_doc: "`t:keyword/0`",
                                     doc:
                                       "Options (with `:name`) for a Redix connection the " <>
                                         "store uses alone, for every command and every " <>
                                         "`WAIT`, instead of `:redix`'s and a `WAIT` pool. " <>
                                         "Share it with nothing: a `WAIT` stalls it."
                                   ],
                                   wait_connections: [
                                     type: :pos_integer,
                                     doc:
                                       "How many connections the store's `WAIT` pool opens " <>
                                         "(default `4`); only when `config :normandy, " <>
                                         ":redis_wait` asks for replicas and without " <>
                                         "`:store_redix`. Given when `:redis_wait` asks " <>
                                         "for none, it raises `ArgumentError`."
                                   ]
                                 )

  @default_wait_connections 4

  @doc """
  Build the distributed-session child specs.

  ## Options

  #{Options.docs(@child_specs_opts_schema)}
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec() | :supervisor.child_spec() | map()]
  def child_specs(opts) do
    opts = Options.validate!(opts, @child_specs_opts_schema, {__MODULE__, :child_specs, 1})
    reg = Keyword.fetch!(opts, :registry)
    sup = Keyword.fetch!(opts, :supervisor)

    libcluster_specs(opts, reg) ++
      [
        %{id: reg, start: {HReg, :start_link, [[name: reg]]}},
        %{id: sup, start: {HSup, :start_link, [[name: sup]]}}
      ] ++
      reaper_specs(opts, reg, sup)
  end

  @doc """
  Create the Mnesia store tables (host setup, not a child spec). Thin pass-through to
  `SessionStore.Mnesia.create_tables/1` — call once at boot before serving sessions.

  ## Options

  The options of `Normandy.Behaviours.SessionStore.Mnesia.create_tables/1`.
  """
  @spec setup_mnesia_store!(keyword()) :: :ok
  def setup_mnesia_store!(opts) do
    opts
    |> Options.validate!(
      MnesiaStore.__opts_schema__(:create_tables),
      {__MODULE__, :setup_mnesia_store!, 1}
    )
    |> MnesiaStore.create_tables()
  end

  @doc """
  Child specs for the **Redis combo** (Redis registry + Redis store + local supervisor +
  reaper) — Redis as the single distributed dependency. `:template_provider` enables the
  `ResumeReaper` for eager handoff. Cross-node routing still uses Erlang distribution.
  `redis_handles/1` returns the registry and store to give `Turn.Session.new/1`.

  The registry and the store share the `:redix` connection, except for the store's waited
  writes. When `config :normandy, :redis_wait` asks for replicas (read here, once), the
  specs also start `:wait_connections` Redix connections, named `:"<redix name>.wait.<i>"`,
  and the store runs each waited write and its `WAIT` on one of them (see
  `Normandy.Behaviours.SessionStore.Redis`). With `:store_redix`, the store uses that
  connection for everything and no pool starts.

  ## Options

  #{Options.docs(@redis_child_specs_opts_schema)}
  """
  @spec redis_child_specs(keyword()) :: [Supervisor.child_spec() | map()]
  def redis_child_specs(opts) do
    opts =
      Options.validate!(opts, @redis_child_specs_opts_schema, {__MODULE__, :redis_child_specs, 1})

    redix = Keyword.fetch!(opts, :redix)
    conn_name = conn_name!(redix, :redis_child_specs)
    ns = Keyword.fetch!(opts, :namespace)
    registry = Keyword.fetch!(opts, :registry)
    supervisor = Keyword.fetch!(opts, :supervisor)
    store = store_setup(opts, :redis_child_specs)
    handles = build_redis_handles(opts, store, :redis_child_specs)

    [{Redix, redix}] ++
      store_conn_specs(opts, store) ++
      [
        %{
          id: registry,
          start: {RedisReg, :start_link, [[name: registry, conn: conn_name, namespace: ns]]}
        },
        %{id: supervisor, start: {LocalSup, :start_link, [[name: supervisor]]}}
      ] ++ redis_reaper_specs(opts, handles, registry, supervisor)
  end

  @doc """
  The `{module, handle}` pairs of the registry and store that `redis_child_specs/1` starts
  for the same options: pass them to `Normandy.Agents.Turn.Session.new/1` as `:registry`
  and `:store`. Starts and calls nothing.

  ## Options

  The options of `redis_child_specs/1`.
  """
  @spec redis_handles(keyword()) :: %{registry: {module(), term()}, store: {module(), term()}}
  def redis_handles(opts) do
    opts
    |> Options.validate!(@redis_child_specs_opts_schema, {__MODULE__, :redis_handles, 1})
    |> then(&build_redis_handles(&1, store_setup(&1, :redis_handles), :redis_handles))
  end

  defp build_redis_handles(opts, store, fun) do
    conn_name = conn_name!(Keyword.fetch!(opts, :redix), fun)
    ns = Keyword.fetch!(opts, :namespace)

    %{
      registry:
        {RedisReg,
         RedisReg.handle(owner: Keyword.fetch!(opts, :registry), conn: conn_name, namespace: ns)},
      store: {RedisStore, store_handle(opts, store)}
    }
  end

  # The store's handle: on :store_redix's connection, or on :redix's with a WAIT pool
  # when the app env asks for replicas. {conn, ns} otherwise, which reads the app env
  # on every write, as any such handle does.
  defp store_handle(opts, {plan, wait, fun}) do
    ns = Keyword.fetch!(opts, :namespace)

    case {plan, wait} do
      {{:own, conn}, {0, _timeout}} -> {conn, ns}
      {{:own, conn}, wait} -> {conn, ns, wait}
      {{:shared, conn}, {0, _timeout}} -> {conn, ns}
      {{:shared, conn}, wait} -> {conn, ns, wait, List.to_tuple(wait_conn_names(opts, fun))}
    end
  end

  defp store_conn_specs(opts, {plan, wait, fun}) do
    case {plan, wait} do
      {{:own, _conn}, _wait} ->
        [Supervisor.child_spec({Redix, Keyword.fetch!(opts, :store_redix)}, id: :store_redix)]

      {{:shared, _conn}, {0, _timeout}} ->
        []

      {{:shared, _conn}, _wait} ->
        redix = Keyword.fetch!(opts, :redix)

        for name <- wait_conn_names(opts, fun),
            do: Supervisor.child_spec({Redix, Keyword.put(redix, :name, name)}, id: name)
    end
  end

  # The store's `{plan, wait}`, computed once per call: the `:redis_wait` app env is read
  # here and nowhere else, so the handle and the WAIT-pool specs agree.
  defp store_setup(opts, fun), do: {store_plan(opts, fun), store_wait!(opts, fun), fun}

  # The app env's wait. :wait_connections sizes a WAIT pool that only starts when it
  # asks for replicas; given without that, it is refused as SessionStore.Redis.new/1
  # refuses it, so a host learns that its writes are not waited.
  defp store_wait!(opts, fun) do
    case {RedisStore.app_env_wait!(), Keyword.has_key?(opts, :wait_connections)} do
      {{0, _timeout}, true} ->
        raise ArgumentError,
              "Normandy.Cluster.#{fun}/1: :wait_connections needs config :normandy, " <>
                ":redis_wait to ask for one replica or more, got 0 replicas"

      {wait, _given} ->
        wait
    end
  end

  defp store_plan(opts, fun) do
    case {Keyword.fetch(opts, :store_redix), Keyword.has_key?(opts, :wait_connections)} do
      {{:ok, _store_redix}, true} ->
        raise ArgumentError,
              "Normandy.Cluster.#{fun}/1: :wait_connections and :store_redix exclude each " <>
                "other (with :store_redix, waited writes run on that connection)"

      {{:ok, store_redix}, false} ->
        {:own, conn_name!(store_redix, fun, :store_redix)}

      {:error, _} ->
        {:shared, conn_name!(Keyword.fetch!(opts, :redix), fun)}
    end
  end

  defp wait_conn_names(opts, fun) do
    conn_name = conn_name!(Keyword.fetch!(opts, :redix), fun)

    unless is_atom(conn_name) do
      raise ArgumentError,
            "Normandy.Cluster.#{fun}/1: with config :normandy, :redis_wait, the :redix " <>
              ":name must be an atom (the WAIT pool is named after it), got: " <>
              Describe.type_of(conn_name)
    end

    k = Keyword.get(opts, :wait_connections, @default_wait_connections)
    for i <- 0..(k - 1), do: :"#{conn_name}.wait.#{i}"
  end

  defp conn_name!(redix, fun, key \\ :redix) do
    case Keyword.fetch(redix, :name) do
      {:ok, name} ->
        name

      :error ->
        raise ArgumentError,
              "Normandy.Cluster.#{fun}/1: #{inspect(key)} must include :name, the Redix " <>
                "connection's registered name"
    end
  end

  defp redis_reaper_specs(opts, handles, registry, supervisor) do
    case Keyword.get(opts, :template_provider) do
      nil ->
        []

      template_provider ->
        [
          %{
            id: {ResumeReaper, registry},
            start:
              {ResumeReaper, :start_link,
               [
                 [
                   store: handles.store,
                   registry: handles.registry,
                   supervisor: supervisor,
                   supervisor_mod: LocalSup,
                   template_provider: template_provider
                 ]
               ]}
          }
        ]
    end
  end

  defp libcluster_specs(opts, reg) do
    topologies = Keyword.fetch!(opts, :topologies)

    if topologies != [] and Code.ensure_loaded?(Cluster.Supervisor) do
      [{Cluster.Supervisor, [topologies, [name: Module.concat(reg, ClusterSupervisor)]]}]
    else
      []
    end
  end

  defp reaper_specs(opts, reg, sup) do
    store = Keyword.get(opts, :store)
    template_provider = Keyword.get(opts, :template_provider)

    if store && template_provider do
      [
        %{
          id: ResumeReaper,
          start:
            {ResumeReaper, :start_link,
             [
               [
                 store: store,
                 registry: {HReg, reg},
                 supervisor: sup,
                 supervisor_mod: HSup,
                 template_provider: template_provider
               ]
             ]}
        }
      ]
    else
      []
    end
  end
end
