# Phase 7 — Distributed Multi-Node Sessions — Design

- **Date:** 2026-06-17
- **Status:** Approved (design); pending implementation plan
- **Author:** Q
- **Origin:** Un-defers the "Distributed multi-node session registry implementation"
  item from the harness-decomposition design
  (`2026-05-29-harness-decomposition-design.md`, *Out of scope*), and the deferred
  Postgres `SessionStore` reference impl, pulling both into the 1.0 milestone.

## Motivation

The harness-decomposition milestone shipped the session **seams** but only in-node
defaults:

- `Normandy.Behaviours.SessionRegistry` + `SessionRegistry.Native` (Elixir `Registry`).
- `Normandy.Behaviours.SessionStore` + `InMemory` / `ETS`.
- `Turn.Session` (router), `Turn.Server` (`:gen_statem` shell, self-registers on
  init, passivates on idle), `Turn.Supervisor` (local `DynamicSupervisor`),
  `Config` (carries `session_registry` / `session_store` refs).

Two follow-ups were deliberately deferred and are documented in-code:

1. `SessionRegistry.Native.register/3` only ever registers `self()` — no foreign-pid
   / `:via` path (`session_registry/native.ex:40-52`).
2. A rehydrate race in `Turn.Session`: between `whereis → :none` and the new child
   registering, two callers can start two servers for one `session_id`; the loser
   gets `{:error, :taken}` (`turn/session.ex:44-48`).

This phase makes sessions **cluster-aware and durable**, fixing both follow-ups as a
side effect, while keeping the in-node defaults observably identical to today.

## Goals

- A session is discoverable and routable from **any node** (`session_id → pid`,
  cluster-wide), with at-most-one active instance (best-effort under partition).
- A session's conversation graph **and** in-flight turn state survive node restarts
  and node loss, via a durable shared store (Postgres).
- **The same deployment config runs unchanged from 1 node to N nodes.** Single-node
  is a first-class, fully-tested tier (a Horde cluster-of-one), not a degraded mode.
- Request-driven sessions recover **lazily** (rehydrate on next request).
  Autonomous/long-running sessions recover **eagerly** (auto-resume on a surviving
  node after node death, with no external trigger).
- Every new piece is **opt-in via config**; the all-defaults path is unchanged.

## Non-goals (this phase)

- **Credential replication across nodes** — *hard non-goal*. Credentials are always
  sourced node-locally and never persisted or gossiped (see Invariants).
- **syn backend** — Horde only. `SessionRegistry.Syn` is a future drop-in against the
  existing contract; syn cannot provide the distributed supervisor this phase needs.
- **Normandy owning cluster formation** — Normandy ships an *optional* cluster helper
  and a documented libcluster example; connecting nodes stays the host's job.
- **JSON-/column-structured persistence of turn state** — turn state and entry
  `content` are opaque Erlang terms (see Codec); a structured codec is out of scope.

## Deployment tiers

Registry and store are **orthogonal config slots**, so single-vs-multi-node and
ephemeral-vs-durable are independent choices. All combinations are supported:

| Tier | Registry | Store | Supervisor | Deployment | New deps |
|---|---|---|---|---|---|
| **0 (default)** | `Native` | `InMemory`/`ETS` | local `DynamicSupervisor` | single node, ephemeral | none |
| **1** | `Native` | `Postgres` | local `DynamicSupervisor` | single node, **durable** | ecto_sql, postgrex |
| **2** | `Horde` | `Postgres` | `Horde.DynamicSupervisor` | **single OR multi node**, durable + cluster-aware | + horde |

Tier 1 falls out for free (Native registry + Postgres store is a valid mix). Tier 2 is
the one that must scale transparently — see Architecture.

## Architecture / topology

Distributed infra is **application-level**: started once per node by the host's
supervision tree and joined into the cluster — *not* owned per `AgentProcess`. The
host starts the Horde registry and Horde supervisor (both Horde members) and
configures the Postgres store; their handles flow into `Config` / `Turn.Session`.

```
 Node A                              Node B
 ├─ SessionRegistry.Horde   ◄──CRDT──►  SessionRegistry.Horde    (one logical registry)
 ├─ Turn.Supervisor.Horde   ◄──CRDT──►  Turn.Supervisor.Horde    (one logical supervisor)
 ├─ Tools.Registry (local)              ├─ Tools.Registry (local) (same code each node)
 ├─ CredentialProvider (local)          ├─ CredentialProvider (local)
 └─ Turn.Server(s1)                     └─ Turn.Server(s2)
                \                          /
                 ▼                        ▼
              SessionStore.Postgres → host Repo   (shared DB = source of truth)
```

**Single = multi, transparently.** The Horde registry and supervisor run with
`members: :auto`, so Horde tracks membership from `Node.list()` as nodes join/leave.
One node → one member (a cluster-of-one, works on `nonode@nohost`, no Erlang
distribution required); connect more nodes → they auto-join with no config change.
"Single vs multiple nodes" is a runtime/topology fact, not a code or config fork.

## Component designs

### 7.1 — `SessionRegistry.Horde`

Implements the existing behaviour over `Horde.Registry` (`keys: :unique`,
`members: :auto`):

- `whereis(handle, sid)` → `Horde.Registry.lookup(handle, sid)` → `{:ok, pid}` | `:none`.
- `register(handle, sid, self())` → `Horde.Registry.register(handle, sid, nil)`,
  mapping `{:error, {:already_registered, _}}` → `{:error, :taken}`.
- `unregister(handle, sid)` → `Horde.Registry.unregister(handle, sid)`.
- `new/1` starts a single-node Horde registry and returns its name (for tests).

Passes the **existing `SessionRegistryContract` verbatim** as a cluster-of-one
(drop-in parity proof).

### 7.2 — Atomic registration via `:via` (fixes both deferred follow-ups)

Add one **optional** behaviour callback:

```elixir
@callback child_name(handle(), session_id()) :: {:via, module(), term()} | :self_register
```

- `Native.child_name/2` → `:self_register` (today's `register_self` path; **untouched**).
- `Horde.child_name/2` → `{:via, Horde.Registry, {handle, session_id}}`.

The supervisor uses `child_name/2` to set the child's `name:`. When a `:via` name is
used, `Turn.Server`'s `register_self/1` becomes a no-op (Horde registers at process
start). This **atomically** fixes both follow-ups: foreign-pid registration *and* the
rehydrate race — a concurrent start anywhere in the cluster returns
`{:error, {:already_started, pid}}`, and the loser routes to the winner.

### 7.3 — `Turn.Supervisor.Horde` + mandatory thin specs

`Turn.Supervisor.Horde` wraps `Horde.DynamicSupervisor` (`strategy: :one_for_one`,
`members: :auto`); `start_server/2` → `Horde.DynamicSupervisor.start_child/2` with the
`:via` name; `{:error, {:already_started, pid}}` is treated as "route to existing".
The local `Turn.Supervisor` stays the default for Tiers 0/1.

**Thin specs are mandatory under Horde.** `Horde.DynamicSupervisor` replicates child
specs across members (that is how it knows what to restart where). Therefore a child
spec must never carry credentials or tool closures. Under Tier 2, `Turn.Server` always
starts from a **thin, serializable spec**:

```
{session_id, registry_handle, store_handle, supervisor_handle, resume_policy}
```

and rebuilds the full `%BaseAgentConfig{}` in `init/1` (see 7.4). Tiers 0/1 keep
today's direct-config spec (a local supervisor's specs are never gossiped).

### 7.4 — Config reconstruction (template-based)

To rebuild config on any node without a caller and without moving secrets, config
splits into two halves:

- **Serializable, non-secret → persisted as the session's config template** (in the
  Postgres store): `model`, `temperature`, `max_tokens`, behaviour refs
  (`{mod, opts}` for policy/budget/credential/compactor/model_catalog/store/registry),
  prompt specification, output-schema module, and the **tool-registry name** (an
  atom resolved locally, never the tool functions). Behaviour `opts` in the template
  must themselves be serializable (atoms/data, no pids or closures); the
  store/registry/supervisor handles travel in the thin spec, not the template, and the
  `credential` ref names *which* provider (e.g. `{CredentialProvider.Env, var: "…"}`),
  never the secret.
- **Node-local, never moved →** credentials (via the `CredentialProvider` behaviour)
  and the actual tool handlers (resolved by name from a node-local `Tools.Registry`
  that every node populates at boot — already how the turn loop resolves tools:
  `Tools.Registry.get(config.tool_registry, call.name)`).

Reconstruction in `Turn.Server.init/1`: load the template from the store, deserialize
it, bind the node-local `tool_registry` and `CredentialProvider`, build the client
from the non-secret model/endpoint params + the locally-fetched token → a full
`%BaseAgentConfig{}`. Normal start and handoff restart take the **identical** path.

**Requirement for the Horde-supervisor tier:** deployments must use a real
env/vault-backed `CredentialProvider` (not `CredentialProvider.FromClient`, which
assumes the secret is already on the in-memory client) and register their tools by
name on every node. Both are normal for a clustered deployment (same code per node).

### 7.5 — `SessionStore.Postgres` (Ecto, host-supplied Repo)

Idiomatic library shape (Oban-style): the host owns, configures, and starts the Repo;
Normandy ships the Ecto schemas, a migration, and `SessionStore.Postgres`, selected
via `{SessionStore.Postgres, repo: MyApp.Repo}`. No second connection pool; no DB
ownership opinions.

**Schema** (two tables; entries are a global parent-linked forest so `fork` shares
ancestors instead of copying):

- `normandy_session_entries`: `id` (uuid, PK), `parent_id` (uuid, null),
  `turn_id` (text), `role` (text), `content` (**bytea**, `term_to_binary`),
  `inserted_at`. Index on `parent_id`.
- `normandy_sessions`: `session_id` (text, PK), `head_id` (uuid, null, → entries.id),
  `current_turn_id` (text, null), `turn_state` (**bytea**, null, `term_to_binary`),
  `config_template` (**bytea**, null, `term_to_binary`; see 7.4), `resume_policy`
  (text), timestamps.

The `handle` is the Ecto Repo module (callbacks read/write through it).

**Operations** (satisfy the existing `SessionStoreContract` verbatim):

- `append_entry/3` — transaction with `SELECT ... FOR UPDATE` on the session row:
  read head, insert entry (`parent_id = entry.parent_id || head`), set head = new id.
  Serializes concurrent appends (incl. cross-node) → the 200-concurrent contract test
  passes; no lost entries, chronological order preserved.
- `history/2` — recursive CTE walking `head → root`, returned chronological. Unknown
  session → `{:ok, []}` (lenient, per contract).
- `fork/3` — strict: error on unknown session/entry; otherwise insert a new session
  row whose `head_id` points at `from_entry_id` (entries shared; appends to the fork
  create children of that entry).
- `save_turn_state/3` / `load_turn_state/2` — upsert / read the `turn_state` blob;
  missing → `:error`.
- `new/0` — for tests; returns the configured Repo module as the handle after an
  Ecto SQL sandbox checkout, satisfying the contract's zero-arg `new()` call.

### 7.6 — Lazy vs eager resume policy

Per-session `resume_policy` (`:lazy` default | `:eager`), persisted on the session
and mapped to the Horde child's `restart` value:

- **`:lazy` → `restart: :temporary`.** On node loss the process is gone and **not**
  redistributed; the session is rebuilt on the next inbound request via the existing
  `whereis → :none → rehydrate` path (now durable cross-node). No restart storm for
  idle sessions. This is the baseline for request-driven sessions.
- **`:eager` → `restart: :transient`.** On node loss Horde redistributes the child to
  a surviving node; `init/1` reconstructs config (7.4), loads turn state, and resumes
  the in-flight turn — no external request needed. For autonomous/long-running agents.
  (`:transient` still does **not** restart on a `:normal` passivation stop.)

> **To verify during 7d:** that `Horde.DynamicSupervisor` honors `restart: :temporary`
> (no redistribution) vs `:transient` (redistribute on node-down) exactly as assumed.
> This is the load-bearing assumption for selective resume; confirm against Horde's
> redistribution semantics before relying on it.

### 7.7 — Wiring

- `Config.session_store` / `session_registry` accept the new refs
  (`{SessionStore.Postgres, repo: …}`, `{SessionRegistry.Horde, …}`).
- `AgentProcess.server_infra/1` already honors caller-supplied
  `store` / `registry` / `supervisor`, so distributed handles drop in unchanged; only
  the *defaults* it starts when none are supplied stay local (Tier 0).
- No dispatch-path or pure-FSM-core changes. `Turn.Session`'s router logic is unchanged
  except that `child_name/2` now drives the child's name and the race is closed by the
  `:via` start.

### 7.8 — Cluster helper (optional) + libcluster example

Ship an optional `Normandy.Cluster` helper and a documented libcluster topology +
supervision-tree example. libcluster is an **optional dependency** (used only if
present); with `members: :auto`, once nodes are connected Horde auto-joins. Connecting
nodes remains the host's responsibility.

## Data flow

- **Route (cross-node):** `Turn.Session.run` → `whereis` returns a pid on any node;
  the `:gen_statem` call is a transparent cross-node message.
- **Start / race:** miss → start under the (Horde) supervisor with the `:via` name; a
  losing concurrent starter gets `{:already_started, pid}` → routes there.
- **Node loss, lazy:** registration drops; next request anywhere → `:none` →
  rehydrate from Postgres (turn state + history) + reconstructed config → start on the
  handling node.
- **Node loss, eager:** Horde redistributes the `:transient` child → `init/1`
  reconstructs config + loads turn state → resumes the in-flight turn, no request.
- **Netsplit:** AP system — single-active is **best-effort**. A partition can
  transiently run two servers for one `session_id`; per-session serialized Postgres
  writes prevent corruption. On heal, Horde's name-conflict resolution terminates the
  loser; its state is durable, so the next interaction rehydrates the survivor.

## Invariants

- **Credentials are never persisted and never replicated.** Always sourced node-locally
  via `CredentialProvider`. (Relaxes the Phase-4 "store never holds config" rule only
  for the *non-secret* config template; the credential half stays a hard invariant.)
- **No secret or closure ever enters a Horde child spec or the CRDT** (thin specs,
  7.3).
- **Fail-closed persistence:** a store write failure at a suspend/turn boundary is a
  hard failure; the turn does not advance past a point it cannot durably record (no
  silent fallback), now over the DB.

## Error handling

- Postgres unreachable / `history` fault → propagates as `Turn.Session.run/2`'s
  `{:error, reason}` (path already exists); writes at boundaries fail the turn closed.
- `term_to_binary` / `binary_to_term` is opaque; **struct-shape drift across deploys
  is a documented fragility** of the reference impl (`binary_to_term` rebuilds the
  persisted shape). `binary_to_term/2` uses `[:safe]`.
- Tool task crash/timeout, LLM failure, handler throw → unchanged (existing envelope /
  Retry / CircuitBreaker / `:failed` handling).

## Testing strategy

- **Contract reuse:** `SessionRegistry.Horde` and `SessionStore.Postgres` pass the
  *existing* `SessionRegistryContract` / `SessionStoreContract` suites verbatim.
- **Single-node Tier-2 (default-run, untagged):** the Horde registry/supervisor and
  the full reconstruct → route → rehydrate path tested as a cluster-of-one, no `:peer`
  setup — the everyday regression coverage that the distributed path stays correct.
- **`:postgres` (excluded by default):** the store against a real DB via Ecto SQL
  sandbox, incl. concurrent/serialized appends and fork isolation.
- **`:distributed` (excluded by default):** `:peer` nodes (OTP 27) — cross-node route,
  race → single winner, node-down → lazy rehydrate elsewhere, node-down → eager
  auto-resume.
- **Back-compat:** the full suite is green with defaults (`Native` / `InMemory`); the
  everything-off path is observably identical to today.

## Phased build order

Dependency-respecting; each phase is independently shippable.

1. **Phase 7a — `SessionStore.Postgres`** (Ecto schemas, migration, codec,
   concurrency, fork; `SessionStoreContract` + `:postgres` tests). Node-agnostic;
   delivers Tier 1. New deps: `ecto_sql`, `postgrex`.
2. **Phase 7b — `SessionRegistry.Horde` + `:via` start.** Behaviour `child_name/2`,
   `Turn.Server` registration change, race fix; `SessionRegistryContract` (cluster-of-one)
   + `:distributed` registry tests. Registry-only distribution (sessions node-pinned
   under the local supervisor, direct config). New dep: `horde`.
3. **Phase 7c — `Turn.Supervisor.Horde` + thin specs + template reconstruction +
   wiring.** Distributed placement; mandatory thin specs (7.3); template-based config
   reconstruction (7.4); `Config`/`AgentProcess` wiring; lazy recovery
   (`restart: :temporary`). Single-node Tier-2 integration → multi-node. Delivers
   Tier 2 (lazy).
4. **Phase 7d — Eager handoff.** `resume_policy` (`:eager` → `restart: :transient`),
   `init/1` auto-resume, node-down auto-resume `:distributed` tests, and verification
   of Horde's restart-strategy redistribution semantics (7.6).
5. **Docs** — optional `Normandy.Cluster` helper + libcluster topology / supervision
   example (7.8).

## Resolved (during this design)

- **Backend:** Horde (registry + distributed supervisor). syn deferred (pluggable).
- **Recovery:** lazy by default; eager for sessions flagged `:eager` (pulled into 1.0).
- **Store:** Postgres via Ecto, host-supplied Repo; turn state + entry content + config
  template persisted as opaque Erlang terms (`term_to_binary`).
- **Reconstruction:** template-based (persist non-secret template; rebuild via
  node-local tool registry + `CredentialProvider`).
- **Single + multi-node:** one config via Horde `members: :auto`; single node is a
  tested cluster-of-one.
- **Cluster formation:** optional `Normandy.Cluster` helper + optional libcluster dep +
  example docs; host connects nodes.

## Open questions (verify during implementation, not blockers)

- **Horde restart-strategy redistribution** (7.6) — confirm `:temporary` is not
  redistributed and `:transient` is, on node-down.
- **Netsplit conflict callback** — confirm Horde's name-conflict resolution terminates
  the loser cleanly and that our `Turn.Server` tolerates being told to stop mid-turn
  with durable state already written.
- **Term codec versioning** — decide whether to stamp persisted blobs with a schema
  version to detect struct drift on load (vs documented fragility only).
