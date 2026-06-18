# Distributed Multi-Node Sessions

Normandy's session layer (the `:gen_statem` turn engine behind `Turn.Server`) is
**pluggable** across three deployment tiers. The registry and the store are
independent choices, so you opt into exactly as much as you need.

| Tier | Registry | Store | Deployment | Extra deps |
|---|---|---|---|---|
| **0 (default)** | `Native` | `InMemory` / `ETS` | single node, ephemeral | none |
| **1** | `Native` | `Postgres` | single node, **durable** | `ecto_sql`, `postgrex` |
| **2** | `Horde` | `Postgres` | **single OR multi node**, durable + cluster-aware | + `horde` |

The same Tier-2 config runs unchanged on one node or N nodes — Horde uses
`members: :auto`, so a single node is a cluster-of-one and additional nodes
auto-join once connected. "Single vs multi-node" is a runtime fact, not a config
fork.

## Tier 1 — durable single node

Run Normandy's migrations into your repo (Oban-style) and select the Postgres
store:

```elixir
# priv/repo/migrations/XXXX_add_normandy_sessions.exs
defmodule MyApp.Repo.Migrations.AddNormandySessions do
  use Ecto.Migration
  def up do
    Normandy.Behaviours.SessionStore.Postgres.Migration.up()
    Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate.up()
    Normandy.Behaviours.SessionStore.Postgres.MigrationAddResumePolicy.up()
  end
  def down do
    Normandy.Behaviours.SessionStore.Postgres.MigrationAddResumePolicy.down()
    Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate.down()
    Normandy.Behaviours.SessionStore.Postgres.Migration.down()
  end
end
```

> The `MigrationAddTemplate` / `MigrationAddResumePolicy` columns are only *used* by
> Tier 2 (template-based reconstruction + eager resume). They're nullable and inert
> under Tier 1, but including them now means a later Tier-2 upgrade needs no extra
> migration. A strictly Tier-1 deployment may run only `Migration.up()` / `.down()`.

Then pass `store: {Normandy.Behaviours.SessionStore.Postgres, MyApp.Repo}` to the
session opts. The store holds the conversation graph, suspended turn state, and a
non-secret config template — all as opaque Erlang terms.

## Tier 2 — distributed, cluster-aware

Start the Horde infra once per node from your supervision tree. The
`Normandy.Cluster` helper builds the child specs:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  # The node-local "supplement" registry: the non-serializable half of agent
  # config (tools, hooks, an LLM-client builder), keyed by template_id. Populate
  # it at boot on EVERY node with the same code.
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
```

Both `store` (the durable Postgres backend) and `template_provider` (the node-local
`AgentTemplate.Catalog`) are **required** for Tier 2 — they are how a session is
rebuilt on another node after failover, and `Normandy.Cluster.child_specs/1` only
starts the `ResumeReaper` when both are present. Tier 1 can omit them.

Register a supplement per agent kind at boot (same on every node):

```elixir
Normandy.Behaviours.AgentTemplate.Catalog.put(MyApp.AgentTemplates, "support-agent", %{
  tool_registry: MyApp.Tools.support_registry(),
  before_hooks: [],
  after_hooks: [],
  client_builder: fn token -> %Claudio.ClaudioAdapter{api_key: token, ...} end
})
```

### How a session moves across nodes

- **Discovery + routing.** `Turn.Session` resolves `session_id → pid` via
  `SessionRegistry.Horde` from any node; calls to a session on another node are
  transparent cross-node `:gen_statem` messages.
- **Atomic placement.** Servers start under a `{:via, Horde.Registry, …}` name, so
  two concurrent starts for one `session_id` cannot both win — the loser gets
  `{:error, {:already_started, pid}}` and routes to the winner.
- **Node loss, lazy (default).** The session's process dies with its node; the next
  request anywhere rebuilds it from Postgres (turn state + history + reconstructed
  config). No restart storm for idle sessions.
- **Node loss, eager.** For sessions started with `resume_policy: :eager`, a
  per-node `Turn.ResumeReaper` watches `:nodedown` and auto-resumes them on a
  surviving node — no inbound request — by reconstructing config and continuing the
  in-flight turn (`Turn.resume/1`). Concurrent reapers are safe (registry
  atomicity). See "Eager handoff" below.

## Credentials: never moved between nodes

Credentials are **never persisted and never replicated**. Only a non-secret config
template (model, behaviour refs, prompt spec, tool-registry name, `resume_policy`)
is stored. On any node, a session reconstructs its full config from that template +
the node-local `AgentTemplate` supplement + a **node-local `CredentialProvider`**.

For Tier 2 you must therefore use an env/vault-backed `CredentialProvider` (NOT
`CredentialProvider.FromClient`, which assumes the secret is already on an
in-memory client) and register your tools by name on every node (true by default —
same code per node).

## Eager handoff (`resume_policy: :eager`)

Most sessions are request-driven and should be **lazy** (the default): they recover
on the next message. Use **`:eager`** only for autonomous/long-running agents that
must keep working after a node dies with no external trigger.

> **Why a reaper and not Horde redistribution?** `Horde.DynamicSupervisor` with
> `members: :auto` does not redistribute a dead node's children (it removes the dead
> member from the CRDT), and its reclaim path ignores `restart` type anyway — so
> `restart`-based eager/lazy selectivity is impossible. Normandy instead ships
> `Turn.ResumeReaper`: a per-node watcher that, on `:nodedown`, restarts only the
> eager, unregistered, non-terminal sessions (found via
> `SessionStore.list_resumable/1`). `Normandy.Cluster.child_specs/1` starts one
> automatically when you pass `:store` + `:template_provider`.

## Cluster formation (libcluster, optional)

Normandy does not own cluster formation and does not depend on `libcluster`. If you
pass `:topologies` to `Normandy.Cluster.child_specs/1` AND your app depends on
`libcluster`, a `Cluster.Supervisor` is started for you; otherwise connect nodes
however you like (`Node.connect/1`, k8s DNS, etc.). Example libcluster config:

```elixir
# config/runtime.exs
config :libcluster,
  topologies: [
    normandy: [strategy: Cluster.Strategy.Gossip]
    # or Cluster.Strategy.Kubernetes.DNS for k8s
  ]
```

Once nodes are connected, Horde's `members: :auto` converges automatically.

See `docs/superpowers/specs/2026-06-17-phase-7-distributed-sessions-design.md` for
the full design and rationale.

## More store/registry backends

The store and registry are independent config slots, so these drop in alongside the
Postgres/Horde defaults:

### `SessionStore.Mnesia` — distributed store, no external DB

OTP-native "distributed ETS". Transactions serialize per-session appends. Configure with
`{Normandy.Behaviours.SessionStore.Mnesia, entries: :normandy_entries, sessions: :normandy_sessions}`
and create the tables at boot:

    Normandy.Cluster.setup_mnesia_store!(
      entries: :normandy_entries,
      sessions: :normandy_sessions,
      copies: :disc_copies,            # durable across full-cluster restart (default)
      nodes: [Node.self() | Node.list()]
    )

`copies: :ram_copies` is faster but only durable while ≥1 replica node stays up
(meaningful only with ≥2 nodes); `:disc_copies` survives a full restart (needs a writable
Mnesia dir, e.g. `-mnesia dir '"/var/lib/normandy_mnesia"'`).

### Redis combo — Redis as the single distributed dependency

`SessionStore.Redis` (Streams) + `SessionRegistry.Redis` (`:via`) + the local supervisor +
the reaper give full lazy rehydrate *and* eager auto-resume with only Erlang distribution
and Redis (no Horde, no Postgres):

    children =
      Normandy.Cluster.redis_child_specs(
        redix: [name: MyApp.SessionRedix, host: "localhost", port: 6379],
        namespace: "normandy",
        registry: MyApp.SessionRegistry,
        supervisor: MyApp.TurnSupervisor,
        template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, MyApp.AgentTemplates}
      )

    # then in Config:
    %Normandy.Behaviours.Config{
      session_store: {Normandy.Behaviours.SessionStore.Redis, {MyApp.SessionRedix, "normandy"}},
      session_registry: {Normandy.Behaviours.SessionRegistry.Redis, MyApp.SessionRegistry}
    }

**Durability ladder.** Strongest: Postgres / `Mnesia(disc_copies)`. Mostly-durable:
Redis with AOF enabled + `config :normandy, :redis_wait, {numreplicas, timeout_ms}` to
block boundary writes on replica acks (fail-closed). Ephemeral: `Mnesia(ram_copies)`,
`ETS`, `InMemory`. Redis can lose recent writes on a hard crash — durable, not bulletproof;
do not use it for audit-grade history.
