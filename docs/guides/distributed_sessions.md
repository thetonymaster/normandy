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
